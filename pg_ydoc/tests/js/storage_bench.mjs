// What a document costs to keep and to serve, three ways:
//
// - one column: a ydoc rewritten on every edit (the shape of Supabase's 2022
//   pg_crdt).
// - log, 64 rows: snapshot + log, compacted every 64 rows, served by merging
//   the two.
// - log, by size: what Y::PgDocument does. Compacts when the log's bytes
//   reach RATIO of the snapshot's stored size (at least MIN_LOG bytes),
//   checked on one append in 16. Serves without decoding the snapshot: the
//   state vector is a stored column extended by the log, and the snapshot
//   and the log go out as two updates.
//
// Each edit is one typed character, as an editor sends it. Writes report WAL,
// dead tuples (autovacuum off) and time per edit, compactions included.
// Joins are timed with the log halfway to its next compaction, for a new
// client (empty state vector) and a returning one missing the last 20 edits;
// a join is the server's two queries, state vector and diff.
//
// Usage: node storage_bench.mjs
// Env: SIZES (2,50,500 KB), EDITS (8000; 640 for one column), RATIO (0.1), MIN_LOG (4096), JOINS (50), PGPORT (28817)
import pg from 'pg'
import * as Y from 'yjs'
import { rng } from './session.mjs'

const SIZES = (process.env.SIZES ?? '2,50,500').split(',').map(Number)
const EDITS = Number(process.env.EDITS ?? 8000)
const COLUMN_EDITS = Math.min(EDITS, 640)
const RATIO = Number(process.env.RATIO ?? 0.1)
const MIN_LOG = Number(process.env.MIN_LOG ?? 4096)
const CHECK_EVERY = 16
const JOINS = Number(process.env.JOINS ?? 50)

const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: 'postgres' })
await c.connect()
await c.query('create extension if not exists pg_ydoc')
await c.query('drop table if exists wb_col, wb_log, wb_doc')
const NOVAC = 'with (autovacuum_enabled = false, toast.autovacuum_enabled = false)'
await c.query(`create table wb_col (id int primary key, body ydoc) ${NOVAC}`)
await c.query(`create table wb_doc (id int primary key, state ydoc,
  state_vector bytea generated always as (ydoc_state_vector(state, gapless => true)) stored) ${NOVAC}`)
await c.query('create table wb_log (id bigserial primary key, document_id int not null, payload bytea not null) with (autovacuum_enabled = false)')
await c.query('create index on wb_log (document_id)')

const MERGED = `(select ydoc_merge_agg(part) doc from (
    select state::bytea part from wb_doc where id = $1
    union all select payload from wb_log where document_id = $1) parts) merged`
const LOG = '(select ydoc_merge_agg(payload) from wb_log where document_id = $1)'
const SPLIT = '(d.state is null or d.state_vector is not null)'
const COMPACT = `with folded as (delete from wb_log where document_id = $1 returning payload)
  update wb_doc set state = ydoc_apply(state, (select ydoc_merge_agg(payload)::bytea from folded)) where id = $1`

const STORES = {
  'one column': {
    tables: ['wb_col'],
    setup: (base) => c.query('insert into wb_col values (1, ydoc_apply(null, $1))', [base]),
    edit: (u) => c.query('update wb_col set body = ydoc_apply(body, $1) where id = 1', [u]),
    join: async (sv) => {
      await c.query('select ydoc_state_vector(body) from wb_col where id = 1')
      await c.query('select ydoc_diff(body, $1, true) from wb_col where id = 1', [sv])
    }
  },
  'log, 64 rows': {
    tables: ['wb_doc', 'wb_log'],
    setup: (base) => c.query('insert into wb_doc values (1, ydoc_apply(null, $1))', [base]),
    edit: async (u) => {
      const { n } = (await c.query(`with i as (insert into wb_log (document_id, payload) values (1, $1))
        select count(*) + 1 n from wb_log where document_id = 1`, [u])).rows[0]
      if (n >= 64) await c.query(COMPACT, [1])
    },
    halfway: async (more) => { for (const u of more.slice(0, 32)) await c.query('insert into wb_log (document_id, payload) values (1, $1)', [u]) },
    join: async (sv) => {
      await c.query(`select ydoc_state_vector(doc) from ${MERGED}`, [1])
      await c.query(`select ydoc_diff(doc, $2, true) from ${MERGED}`, [1, sv])
    }
  },
  'log, by size': {
    tables: ['wb_doc', 'wb_log'],
    setup: (base) => c.query('insert into wb_doc values (1, ydoc_apply(null, $1))', [base]),
    edit: async (u) => {
      const { due } = (await c.query(`with i as (insert into wb_log (document_id, payload) values (1, $1) returning id)
        select (select id from i) % $2::int = 0
           and (select coalesce(sum(octet_length(payload)), 0) from wb_log where document_id = 1)
               >= greatest($3::bigint, $4::float8 * (select coalesce(pg_column_size(state), 0) from wb_doc where id = 1)) due`,
      [u, CHECK_EVERY, MIN_LOG, RATIO])).rows[0]
      if (due) await c.query(COMPACT, [1])
    },
    halfway: async (more) => {
      const { size } = (await c.query('select pg_column_size(state) size from wb_doc where id = 1')).rows[0]
      const target = Math.max(MIN_LOG, RATIO * size) / 2
      let bytes = 0
      for (const u of more) {
        if (bytes >= target) break
        await c.query('insert into wb_log (document_id, payload) values (1, $1)', [u])
        bytes += u.length
      }
    },
    join: async (sv) => {
      await c.query(`select case when ${SPLIT} then ydoc_extend_state_vector(d.state_vector, ${LOG})
                                 else (select ydoc_state_vector(doc) from ${MERGED}) end
                       from wb_doc d where d.id = $1`, [1])
      await c.query(`select case when ${SPLIT} then coalesce(ydoc_diff(d.state, $2, true), ydoc()::bytea)
                                 else (select ydoc_diff(coalesce(doc, ydoc()), $2, true) from ${MERGED}) end,
                            case when ${SPLIT} then ydoc_diff(${LOG}, $2, true) end
                       from wb_doc d where d.id = $1`, [1, sv])
    }
  }
}

// A document of about kb KB built from many inserts and some deletes, so it
// has realistic structure, then one-character edits.
function workload (kb, r, edits) {
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
  const out = []
  doc.on('update', (u) => out.push(Buffer.from(u)))
  let at = Math.floor(r.rand() * text.length)
  for (let i = 0; i < edits; i++) {
    if (i % 200 === 199) at = Math.floor(r.rand() * text.length) // move the cursor now and then
    text.insert(at++, String.fromCharCode(97 + (i % 26)))
  }
  return { base, edits: out, doc }
}

const one = async (sql, args) => (await c.query(sql, args)).rows[0]
async function dead (tables) {
  await c.query('select pg_stat_force_next_flush()')
  return (await one(`select coalesce(sum(n_dead_tup), 0)::int n from pg_stat_all_tables
     where relid in (select oid from pg_class where relname = any($1)
                     union select reltoastrelid from pg_class where relname = any($1) and reltoastrelid <> 0)`, [tables])).n
}
const size = async (tables) => Number((await one('select sum(pg_total_relation_size(t::regclass))::bigint s from unnest($1::text[]) t', [tables])).s)
async function time (n, fn) {
  const t0 = performance.now()
  for (let i = 0; i < n; i++) await fn(i)
  return (performance.now() - t0) / n
}
const kb = (b) => `${(b / 1024).toFixed(2)} KB`

const rows = []
for (const sizeKb of SIZES) {
  const { base, edits } = workload(sizeKb, rng(sizeKb), EDITS + 8000)
  for (const [name, s] of Object.entries(STORES)) {
    const n = name === 'one column' ? COLUMN_EDITS : EDITS
    await c.query('truncate wb_col, wb_doc, wb_log')
    await s.setup(base)
    await c.query('checkpoint')
    const deadBefore = await dead(s.tables)
    const sizeBefore = await size(s.tables)
    const from = (await one('select pg_current_wal_insert_lsn() l')).l
    const ms = await time(n, (i) => s.edit(edits[i]))
    const wal = Number((await one('select pg_wal_lsn_diff(pg_current_wal_insert_lsn(), $1) b', [from])).b)
    const deadPer = ((await dead(s.tables)) - deadBefore) / n
    const grew = (await size(s.tables)) - sizeBefore
    // Joins: compact (if a log), fill the log halfway, then serve.
    if (s.halfway) {
      await c.query(COMPACT, [1])
      await s.halfway(edits.slice(n))
    }
    const all = new Y.Doc()
    Y.applyUpdate(all, base)
    const served = n + (s.halfway ? (await one('select count(*)::int k from wb_log')).k : 0)
    for (const u of edits.slice(0, Math.max(0, served - 20))) Y.applyUpdate(all, u)
    const returning = Buffer.from(Y.encodeStateVector(all))
    const joinNew = await time(JOINS, () => s.join(Buffer.from([0])))
    const joinBack = await time(JOINS, () => s.join(returning))
    rows.push({
      doc: `${sizeKb} KB`,
      store: name,
      'WAL/edit': kb(wal / n),
      'dead/edit': deadPer.toFixed(2),
      'growth/edit': kb(grew / n),
      'ms/edit': ms.toFixed(3),
      'new join ms': joinNew.toFixed(2),
      'returning join ms': joinBack.toFixed(2)
    })
  }
}
await c.query('drop table wb_col, wb_doc, wb_log')
await c.end()
console.log(`one-character edits (${COLUMN_EDITS} for one column, ${EDITS} for the logs); by size: ratio ${RATIO}, min ${MIN_LOG} B; autovacuum off`)
console.table(rows)
