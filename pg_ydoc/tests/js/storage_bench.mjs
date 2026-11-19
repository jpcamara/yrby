// Write amplification: WAL, dead tuples and time per edit, for a ydoc kept
// in one column and rewritten on every edit (the shape of Supabase's 2022
// pg_crdt) against a snapshot + log that compacts every COMPACT_EVERY rows
// (the SQL Y::PgDocument runs). Also the cost of serving a joining client.
//
// Each edit is one typed character, as an editor sends it. Autovacuum is off
// on the tables so dead tuples can be counted.
//
// Usage: node storage_bench.mjs   Env: EDITS (640), COMPACT_EVERY (64), SIZES (2,50,500 KB), PGPORT (28817)
import pg from 'pg'
import * as Y from 'yjs'
import { rng } from './session.mjs'

const EDITS = Number(process.env.EDITS ?? 640)
const COMPACT_EVERY = Number(process.env.COMPACT_EVERY ?? 64)
const SIZES = (process.env.SIZES ?? '2,50,500').split(',').map(Number)
const JOINS = 20

const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: 'postgres' })
await c.connect()
await c.query('create extension if not exists pg_ydoc')
await c.query('drop table if exists wb_col, wb_doc, wb_log')
await c.query('create table wb_col (id int primary key, body ydoc) with (autovacuum_enabled = false, toast.autovacuum_enabled = false)')
await c.query('create table wb_doc (id int primary key, state ydoc) with (autovacuum_enabled = false, toast.autovacuum_enabled = false)')
await c.query('create table wb_log (id bigserial primary key, document_id int not null, payload bytea not null) with (autovacuum_enabled = false)')
await c.query('create index on wb_log (document_id)')

const MERGED = `(select ydoc_merge_agg(part) doc from (
    select state::bytea part from wb_doc where id = $1
    union all select payload from wb_log where document_id = $1) parts) merged`
const APPEND = `with inserted as (insert into wb_log (document_id, payload) values ($1, $2))
  select count(*) + 1 n from wb_log where document_id = $1`
const COMPACT = `with folded as (delete from wb_log where document_id = $1 returning payload)
  update wb_doc set state = ydoc_apply(state, (select ydoc_merge_agg(payload)::bytea from folded)) where id = $1`

// A document of about kb KB built from many inserts and some deletes, so it
// has realistic structure, and the edits that follow: one character each.
function workload (kb, r) {
  const doc = new Y.Doc()
  const text = doc.getText('t')
  const word = () => Array.from({ length: 1 + Math.floor(r.rand() * 12) }, () => String.fromCharCode(97 + Math.floor(r.rand() * 26))).join('') + ' '
  while (Y.encodeStateAsUpdate(doc).length < kb * 1024) {
    for (let i = 0; i < 50; i++) {
      if (r.rand() < 0.15 && text.length > 20) text.delete(Math.floor(r.rand() * (text.length - 10)), 1 + Math.floor(r.rand() * 8))
      else text.insert(Math.floor(r.rand() * (text.length + 1)), word())
    }
  }
  const base = Buffer.from(Y.encodeStateAsUpdate(doc))
  const edits = []
  doc.on('update', (u) => edits.push(Buffer.from(u)))
  let at = Math.floor(r.rand() * text.length)
  for (let i = 0; i < EDITS; i++) text.insert(at++, String.fromCharCode(97 + (i % 26)))
  return { base, edits }
}

const one = async (sql, args) => (await c.query(sql, args)).rows[0]
const lsn = async () => (await one('select pg_current_wal_insert_lsn() l')).l
const walSince = async (from) => Number((await one('select pg_wal_lsn_diff(pg_current_wal_insert_lsn(), $1) b', [from])).b)
async function dead (tables) {
  await c.query('select pg_stat_force_next_flush()')
  const { rows } = await c.query(`
    select sum(s.n_dead_tup)::int n from pg_stat_all_tables s
     where s.relid in (select oid from pg_class where relname = any($1)
                       union select reltoastrelid from pg_class where relname = any($1) and reltoastrelid <> 0)`, [tables])
  return rows[0].n ?? 0
}
const size = async (tables) => Number((await one('select sum(pg_total_relation_size(t::regclass))::bigint s from unnest($1::text[]) t', [tables])).s)
async function time (n, fn) {
  const t0 = performance.now()
  for (let i = 0; i < n; i++) await fn(i)
  return (performance.now() - t0) / n
}

const kb = (b) => `${(b / 1024).toFixed(1)} KB`
const rows = []
for (const size_kb of SIZES) {
  const { base, edits } = workload(size_kb, rng(size_kb))
  for (const [name, tables, setup, edit, join] of [
    ['one column', ['wb_col'],
      () => c.query('insert into wb_col values (1, ydoc_apply(null, $1))', [base]),
      (u) => c.query('update wb_col set body = ydoc_apply(body, $1) where id = 1', [u]),
      () => c.query('select ydoc_diff(body, null, true) from wb_col where id = 1')],
    ['snapshot + log', ['wb_doc', 'wb_log'],
      () => c.query('insert into wb_doc values (1, ydoc_apply(null, $1))', [base]),
      async (u) => { if ((await one(APPEND, [1, u])).n >= COMPACT_EVERY) await c.query(COMPACT, [1]) },
      () => c.query(`select ydoc_diff(coalesce(doc, ydoc()), null, true) from ${MERGED}`, [1])]
  ]) {
    await c.query('truncate wb_col, wb_doc, wb_log')
    await setup()
    await c.query('checkpoint')
    const before = await dead(tables)
    const sizeBefore = await size(tables)
    const from = await lsn()
    const ms = await time(edits.length, (i) => edit(edits[i]))
    const wal = await walSince(from)
    const deadAfter = (await dead(tables)) - before
    const grew = (await size(tables)) - sizeBefore
    // Serving a joining client, with the log half full for the log store.
    if (name === 'snapshot + log') for (const u of edits.slice(0, COMPACT_EVERY / 2)) await c.query(APPEND, [1, u])
    const joinMs = await time(JOINS, join)
    rows.push({ doc: `${size_kb} KB`, store: name, 'WAL/edit': kb(wal / edits.length), 'dead tuples': deadAfter, 'table growth': kb(grew), 'ms/edit': ms.toFixed(2), 'ms/join': joinMs.toFixed(2) })
  }
}
await c.query('drop table wb_col, wb_doc, wb_log')
await c.end()
console.log(`${EDITS} one-character edits, compaction every ${COMPACT_EVERY} log rows, autovacuum off`)
console.table(rows)
