// Storage measurement: one merged document per row vs a snapshot plus an
// update log. Replays a Yjs typing session into Postgres one update per
// statement (as a sync server would) and reports time, WAL and table size.
//
// Usage: node storage_bench.mjs [base_kb ...]   (default: 2 50 500)
// Env:   PGPORT (28817), PGDATABASE (postgres), EDITS (1000), COMPACT_EVERY (200)
import pg from 'pg'
import * as Y from 'yjs'

const EDITS = Number(process.env.EDITS ?? 1000)
const COMPACT_EVERY = Number(process.env.COMPACT_EVERY ?? 200)
const bases = process.argv.slice(2).map(Number)
if (bases.length === 0) bases.push(2, 50, 500)

// Deterministic PRNG so runs are comparable.
function rng (seed) {
  return () => {
    seed = (seed * 1664525 + 1013904223) >>> 0
    return seed / 2 ** 32
  }
}

function workload (baseKb) {
  const rand = rng(42)
  const doc = new Y.Doc()
  const text = doc.getText('body')
  const words = ['lorem ', 'ipsum ', 'dolor ', 'sit ', 'amet ', 'tempor ', 'magna ']
  // The base document arrives as one update, like an initial save.
  let base = ''
  while (base.length < baseKb * 1024) base += words[Math.floor(rand() * words.length)]
  text.insert(0, base)
  const seed = Y.encodeStateAsUpdate(doc)
  const updates = []
  doc.on('update', (u) => updates.push(u))
  for (let i = 0; i < EDITS; i++) {
    const len = text.length
    if (rand() < 0.2 && len > 10) {
      text.delete(Math.floor(rand() * (len - 5)), 1 + Math.floor(rand() * 4))
    } else {
      // Mostly typing near a cursor that drifts, like a real session.
      const at = Math.min(len, Math.floor(len * 0.5 + (rand() - 0.5) * 200))
      text.insert(Math.max(0, at), words[Math.floor(rand() * words.length)])
    }
  }
  return { seed, updates, expected: text.toString() }
}

const textOf = (bytes) => {
  const d = new Y.Doc()
  Y.applyUpdate(d, bytes)
  return d.getText('body').toString()
}

async function walNow (c) {
  return (await c.query('select pg_current_wal_lsn() as l')).rows[0].l
}
async function walSince (c, lsn) {
  return Number((await c.query('select pg_wal_lsn_diff(pg_current_wal_lsn(), $1) as d', [lsn])).rows[0].d)
}
async function size (c, rel) {
  return Number((await c.query('select pg_total_relation_size($1) as s', [rel])).rows[0].s)
}

async function merged (c, w) {
  await c.query('drop table if exists bench_merged')
  await c.query('create table bench_merged (id int primary key, body ydoc not null)')
  await c.query('insert into bench_merged values (1, ydoc($1))', [Buffer.from(w.seed)])
  await c.query('checkpoint')
  const lsn = await walNow(c)
  const t0 = performance.now()
  for (const u of w.updates) {
    await c.query('update bench_merged set body = ydoc_apply(body, $1) where id = 1', [Buffer.from(u)])
  }
  const writeMs = performance.now() - t0
  const wal = await walSince(c, lsn)
  const before = await size(c, 'bench_merged')
  const r0 = performance.now()
  const body = (await c.query('select body::bytea as body from bench_merged where id = 1')).rows[0].body
  const readMs = performance.now() - r0
  await c.query('vacuum bench_merged')
  return { writeMs, wal, sizeBefore: before, sizeAfter: await size(c, 'bench_merged'), readMs, docBytes: body.length, ok: textOf(body) === w.expected }
}

const MERGED_READ = `
  select ydoc_merge_agg(u)::bytea as body from (
    select body::bytea as u from bench_snap where id = 1
    union all
    select u from bench_log where doc_id = 1
  ) parts`

async function compact (c) {
  // Fold the tail into the snapshot and delete what was folded, in one
  // transaction. (yrby-core's plan() also quarantines rows with a causal gap;
  // this workload has none.)
  await c.query('begin')
  const { rows } = await c.query(`
    select max(id) as upto, ydoc_merge_agg(u)::bytea as tail
    from bench_log where doc_id = 1`)
  if (rows[0].upto != null) {
    await c.query('update bench_snap set body = ydoc_apply(body, $1) where id = 1', [rows[0].tail])
    await c.query('delete from bench_log where doc_id = 1 and id <= $1', [rows[0].upto])
  }
  await c.query('commit')
}

async function logged (c, w) {
  await c.query('drop table if exists bench_snap, bench_log')
  await c.query('create table bench_snap (id int primary key, body ydoc not null)')
  await c.query('create table bench_log (id bigserial primary key, doc_id int not null, u bytea not null)')
  await c.query('create index on bench_log (doc_id, id)')
  await c.query('insert into bench_snap values (1, ydoc($1))', [Buffer.from(w.seed)])
  await c.query('checkpoint')
  const lsn = await walNow(c)
  const t0 = performance.now()
  let i = 0
  for (const u of w.updates) {
    await c.query('insert into bench_log (doc_id, u) values (1, $1)', [Buffer.from(u)])
    if (COMPACT_EVERY > 0 && ++i % COMPACT_EVERY === 0) await compact(c)
  }
  const writeMs = performance.now() - t0
  const wal = await walSince(c, lsn)
  // Leave a partial tail so the read pays for a merge, as it would mid-session.
  const tail = Number((await c.query('select count(*) as n from bench_log')).rows[0].n)
  const before = await size(c, 'bench_snap') + await size(c, 'bench_log')
  const r0 = performance.now()
  const body = (await c.query(MERGED_READ)).rows[0].body
  const readMs = performance.now() - r0
  await c.query('vacuum bench_snap'); await c.query('vacuum bench_log')
  const after = await size(c, 'bench_snap') + await size(c, 'bench_log')
  return { writeMs, wal, sizeBefore: before, sizeAfter: after, readMs, docBytes: body.length, tail, ok: textOf(body) === w.expected }
}

const kb = (n) => (n / 1024).toFixed(0) + ' KB'
const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: process.env.PGDATABASE ?? 'postgres' })
await c.connect()
await c.query('create extension if not exists pg_yrby')
console.log(`${EDITS} edits, one statement each; log compacts every ${COMPACT_EVERY}\n`)
console.log('base    strategy  write ms  per edit  WAL        size→vacuum      read ms  doc     ok')
for (const base of bases) {
  const w = workload(base)
  for (const [name, run] of [['merged', merged], ['log', logged]]) {
    const r = await run(c, w)
    console.log([
      `${base} KB`.padEnd(7), name.padEnd(9), r.writeMs.toFixed(0).padStart(8),
      (r.writeMs / EDITS).toFixed(2).padStart(8) + 'ms', kb(r.wal).padStart(10),
      `${kb(r.sizeBefore)}→${kb(r.sizeAfter)}`.padStart(16), r.readMs.toFixed(1).padStart(8),
      kb(r.docBytes).padStart(7), r.ok ? 'yes' : 'NO'
    ].join(' '))
  }
}
await c.query('drop table if exists bench_merged, bench_snap, bench_log')
await c.end()
