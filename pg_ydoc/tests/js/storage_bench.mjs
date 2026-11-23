// What a document costs to keep and to serve, three ways:
//
// - one column: a ydoc rewritten on every edit (the shape of Supabase's 2022
//   pg_crdt).
// - log, 64 rows: snapshot + log, compacted every 64 rows, served by merging
//   the two.
// - log, by size: compacts when the log's bytes reach RATIO of the
//   snapshot's stored size (at least MIN_LOG bytes), checked on one append
//   in 16, deleting the rows it folds. Serves without decoding the snapshot:
//   the state vector is a stored column extended by the log, and the
//   snapshot and the log go out as two updates.
// - log, truncate: what Y::PgDocument does. The same, but the log is
//   insert-only in two partitions: compaction records the snapshot it folded
//   under instead of deleting, and every ROTATE_EVERY edits rotation copies
//   the older partition's unfolded rows forward and truncates it.
//
// Each edit is one typed character, as an editor sends it. Writes report WAL,
// dead tuples (autovacuum off) and time per edit, compactions included.
// Joins are timed with the log halfway to its next compaction, for a new
// client (empty state vector) and a returning one missing the last 20 edits;
// a join is the server's two queries, state vector and diff.
//
// Usage: node storage_bench.mjs
// Env: SIZES (2,50,500 KB), EDITS (8000; 640 for one column), RATIO (0.1), MIN_LOG (4096), ROTATE_EVERY (2000),
//      JOINS (50), PGPORT (28817)
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
const ROTATE_EVERY = Number(process.env.ROTATE_EVERY ?? 2000)

const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: 'postgres' })
await c.connect()
await c.query('create extension if not exists pg_ydoc')
await c.query('drop table if exists wb_col, wb_log, wb_doc, wt_log, wt_doc, wt_rot')
const NOVAC = 'with (autovacuum_enabled = false, toast.autovacuum_enabled = false)'
await c.query(`create table wb_col (id int primary key, body ydoc) ${NOVAC}`)
await c.query(`create table wb_doc (id int primary key, state ydoc,
  state_vector bytea generated always as (ydoc_state_vector(state, gapless => true)) stored) ${NOVAC}`)
await c.query('create table wb_log (id bigserial primary key, document_id int not null, payload bytea not null) with (autovacuum_enabled = false)')
await c.query('create index on wb_log (document_id)')

// The truncate store: an insert-only log in two partitions. Compaction
// records the snapshot it folded under instead of deleting rows; reads skip
// rows that snapshot covers. Rotation copies the old partition's unfolded
// rows into the current one, truncates the old one and makes it current.
await c.query(`create table wt_doc (id int primary key, state ydoc,
  state_vector bytea generated always as (ydoc_state_vector(state, gapless => true)) stored,
  folded pg_snapshot) ${NOVAC}`)
await c.query(`create table wt_log (document_id int not null, txid xid8 not null default pg_current_xact_id(),
  slot smallint not null, payload bytea not null) partition by list (slot)`)
for (const p of [0, 1]) await c.query(`create table wt_log_${p} partition of wt_log for values in (${p}) with (autovacuum_enabled = false)`)
await c.query('create index on wt_log (document_id, txid)')
await c.query('create table wt_rot (slot smallint not null)')
await c.query('insert into wt_rot values (0)')

const MERGED = `(select ydoc_merge_agg(part) doc from (
    select state::bytea part from wb_doc where id = $1
    union all select payload from wb_log where document_id = $1) parts) merged`
const LOG = '(select ydoc_merge_agg(payload) from wb_log where document_id = $1)'
const SPLIT = '(d.state is null or d.state_vector is not null)'
const COMPACT = `with folded as (delete from wb_log where document_id = $1 returning payload)
  update wb_doc set state = ydoc_apply(state, (select ydoc_merge_agg(payload)::bytea from folded)) where id = $1`

// Log rows of document d.id not yet folded into its snapshot.
// The txid lower bound is its own condition so the (document_id, txid) index
// skips folded rows still waiting for their partition's truncate.
const UNFOLDED = (l) => `${l}.document_id = d.id and ${l}.txid >= coalesce(pg_snapshot_xmin(d.folded), '0'::xid8)
  and (d.folded is null or not pg_visible_in_snapshot(${l}.txid, d.folded))`
const T_LOG = `(select ydoc_merge_agg(l.payload) from wt_log l where ${UNFOLDED('l')})`
const T_MERGED = `(select ydoc_merge_agg(part) doc from (
    select d.state::bytea part union all select l.payload from wt_log l where ${UNFOLDED('l')}) parts)`
const T_COMPACT = `update wt_doc d set state = ydoc_apply(d.state, ${T_LOG}::bytea), folded = pg_current_snapshot() where d.id = $1`
let sinceRotate = 0
async function rotate () {
  await c.query('begin')
  try {
    const { slot } = (await c.query('select slot from wt_rot')).rows[0]
    const old = 1 - slot
    await c.query(`lock table wt_log_${old} in access exclusive mode nowait`)
    await c.query(`insert into wt_log (document_id, txid, slot, payload)
      select l.document_id, l.txid, ${slot}, l.payload from wt_log_${old} l join wt_doc d on ${UNFOLDED('l')}`)
    await c.query(`truncate wt_log_${old}`)
    await c.query('update wt_rot set slot = $1', [old])
    await c.query('commit')
  } catch (e) {
    await c.query('rollback')
    if (e.code !== '55P03') throw e // lock_not_available: try next time
  }
}

const STORES = {
  'one column': {
    tables: ['wb_col'],
    read: async () => (await one('select body::bytea b from wb_col where id = 1')).b,
    setup: (base) => c.query('insert into wb_col values (1, ydoc_apply(null, $1))', [base]),
    edit: (u) => c.query('update wb_col set body = ydoc_apply(body, $1) where id = 1', [u]),
    join: async (sv) => {
      await c.query('select ydoc_state_vector(body) from wb_col where id = 1')
      await c.query('select ydoc_diff(body, $1, true) from wb_col where id = 1', [sv])
    }
  },
  'log, 64 rows': {
    tables: ['wb_doc', 'wb_log'],
    read: async () => (await one(`select doc::bytea b from ${MERGED}`, [1])).b,
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
  'log, truncate': {
    tables: ['wt_doc', 'wt_log_0', 'wt_log_1', 'wt_rot'],
    read: async () => (await one(`select (select doc from ${T_MERGED})::bytea b from wt_doc d where d.id = 1`)).b,
    setup: (base) => c.query('insert into wt_doc values (1, ydoc_apply(null, $1))', [base]),
    compact: () => c.query(T_COMPACT, [1]),
    logRows: async () => (await c.query(`select count(*)::int k from wt_doc d, wt_log l where d.id = 1 and ${UNFOLDED('l')}`)).rows[0].k,
    edit: async (u) => {
      const { due } = (await c.query(`with i as (insert into wt_log (document_id, slot, payload)
          values (1, (select slot from wt_rot), $1) returning txid)
        select (select txid from i)::text::bigint % $2::int = 0
           and (select coalesce(sum(octet_length(l.payload)), 0) from wt_doc d, wt_log l where d.id = 1 and ${UNFOLDED('l')})
               >= greatest($3::bigint, $4::float8 * (select coalesce(pg_column_size(state), 0) from wt_doc where id = 1)) due`,
      [u, CHECK_EVERY, MIN_LOG, RATIO])).rows[0]
      if (due) await c.query(T_COMPACT, [1])
      if (++sinceRotate >= ROTATE_EVERY) { sinceRotate = 0; await rotate() }
    },
    halfway: async (more) => {
      const { size } = (await c.query('select pg_column_size(state) size from wt_doc where id = 1')).rows[0]
      const target = Math.max(MIN_LOG, RATIO * size) / 2
      let bytes = 0
      for (const u of more) {
        if (bytes >= target) break
        await c.query('insert into wt_log (document_id, slot, payload) values (1, (select slot from wt_rot), $1)', [u])
        bytes += u.length
      }
    },
    join: async (sv) => {
      await c.query(`select case when ${SPLIT} then ydoc_extend_state_vector(d.state_vector, ${T_LOG})
                                 else (select ydoc_state_vector(doc) from ${T_MERGED} m) end
                       from wt_doc d where d.id = $1`, [1])
      await c.query(`select case when ${SPLIT} then coalesce(ydoc_diff(d.state, $2, true), ydoc()::bytea)
                                 else (select ydoc_diff(coalesce(doc, ydoc()), $2, true) from ${T_MERGED} m) end,
                            case when ${SPLIT} then ydoc_diff(${T_LOG}, $2, true) end
                       from wt_doc d where d.id = $1`, [1, sv])
    }
  },
  'log, by size': {
    tables: ['wb_doc', 'wb_log'],
    read: async () => (await one(`select doc::bytea b from ${MERGED}`, [1])).b,
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
    await c.query('truncate wb_col, wb_doc, wb_log, wt_doc, wt_log')
    sinceRotate = 0
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
      await (s.compact ? s.compact() : c.query(COMPACT, [1]))
      await s.halfway(edits.slice(n))
    }
    const all = new Y.Doc()
    Y.applyUpdate(all, base)
    const logged = s.logRows ? await s.logRows() : s.halfway ? (await one('select count(*)::int k from wb_log')).k : 0
    const served = n + logged
    for (const u of edits.slice(0, Math.max(0, served - 20))) Y.applyUpdate(all, u)
    const returning = Buffer.from(Y.encodeStateVector(all))
    const check = new Y.Doc()
    Y.applyUpdate(check, base)
    for (const u of edits.slice(0, served)) Y.applyUpdate(check, u)
    const stored = new Y.Doc()
    Y.applyUpdate(stored, await s.read())
    if (stored.getText('t').toString() !== check.getText('t').toString()) throw new Error(`${name} at ${sizeKb} KB: stored document is wrong`)
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
await c.query('drop table wb_col, wb_doc, wb_log, wt_log, wt_doc, wt_rot')
await c.end()
console.log(`one-character edits (${COLUMN_EDITS} for one column, ${EDITS} for the logs); by size: ratio ${RATIO}, min ${MIN_LOG} B; autovacuum off`)
console.table(rows)
