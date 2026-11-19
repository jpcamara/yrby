// Concurrency: many connections writing the same document at once.
//
// Each round, a random Yjs session's updates (shuffled, about 10% sent twice)
// are split across WRITERS connections that run at the same time. Every
// writer applies each update to one merged ydoc row and appends it to a
// snapshot + log pair; some writers wrap a few updates in one transaction.
// Meanwhile one connection compacts the log over and over, and another reads
// the snapshot + log and checks that the state vector never goes backwards (a
// compaction that is not atomic would show a read missing folded rows).
// A third store keeps an insert-only log in two partitions: compaction
// records the snapshot it folded under instead of deleting, and a rotator
// copies the old partition's unfolded rows forward and truncates it, while
// everything else runs.
// At the end every store must match the JS peers, with nothing pending.
//
// Usage: node concurrency.mjs   Env: ROUNDS (10), WRITERS (8), PEERS (6), STEPS (200), SEED, PGPORT (28817)
import pg from 'pg'
import * as Y from 'yjs'
import { canon, docFrom, rng, session, snapshotOf } from './session.mjs'

const ROUNDS = Number(process.env.ROUNDS ?? 10)
const WRITERS = Number(process.env.WRITERS ?? 8)
const PEERS = Number(process.env.PEERS ?? 6)
const STEPS = Number(process.env.STEPS ?? 200)
const firstSeed = Number(process.env.SEED ?? Date.now() % 1e9)
const r = rng(firstSeed)

const connect = async () => {
  const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: 'postgres' })
  await c.connect()
  return c
}
const admin = await connect()
await admin.query('create extension if not exists pg_ydoc')
await admin.query('drop table if exists cc_doc, cc_log, cc_snap, cc_tdoc, cc_tlog, cc_rot')
await admin.query('create table cc_tdoc (id int primary key, body ydoc not null, folded pg_snapshot)')
await admin.query(`create table cc_tlog (doc_id int not null, txid xid8 not null default pg_current_xact_id(),
  slot smallint not null, u bytea not null) partition by list (slot)`)
for (const p of [0, 1]) await admin.query(`create table cc_tlog_${p} partition of cc_tlog for values in (${p})`)
await admin.query('create index on cc_tlog (doc_id, txid)')
await admin.query('create table cc_rot (slot smallint not null)')
await admin.query('insert into cc_rot values (0)')
await admin.query('create table cc_doc (id int primary key, body ydoc)')
await admin.query('create table cc_snap (id int primary key, body ydoc not null)')
await admin.query('create table cc_log (id bigserial primary key, doc_id int not null, u bytea not null)')
await admin.query('create index on cc_log (doc_id, id)')
const writers = await Promise.all(Array.from({ length: WRITERS }, connect))
const compactor = await connect()
const reader = await connect()
const rotator = await connect()

const COMPACT = `
  with folded as (delete from cc_log where doc_id = $1 returning u)
  update cc_snap set body = ydoc_apply(body, (select ydoc_merge_agg(u)::bytea from folded))
   where id = $1`
const READ = `
  select ydoc_merge_agg(x)::bytea b from (
    select body::bytea x from cc_snap where id = $1
    union all select u from cc_log where doc_id = $1) t`
// Measured on a Doc, not with Y.encodeStateVectorFromUpdate: that counts a
// leading Skip as content when it is the update's first struct (Yjs 13.6), so
// a gapped read looks further along than it is.
const UNFOLDED = (l) => `${l}.doc_id = d.id and ${l}.txid >= coalesce(pg_snapshot_xmin(d.folded), '0'::xid8)
  and (d.folded is null or not pg_visible_in_snapshot(${l}.txid, d.folded))`
const T_COMPACT = `update cc_tdoc d set body = ydoc_apply(d.body,
    (select ydoc_merge_agg(l.u)::bytea from cc_tlog l where ${UNFOLDED('l')})), folded = pg_current_snapshot()
  where d.id = $1`
const T_READ = `select ydoc_merge_agg(x)::bytea b from (
    select d.body::bytea x from cc_tdoc d where d.id = $1
    union all select l.u from cc_tdoc d join cc_tlog l on ${UNFOLDED('l')} where d.id = $1) t`
let rotations = 0
async function rotate (c) {
  await c.query('begin')
  try {
    await c.query("set local lock_timeout = '20ms'")
    const { slot } = (await c.query('select slot from cc_rot')).rows[0]
    const old = 1 - slot
    await c.query(`lock table cc_tlog_${old} in access exclusive mode`)
    await c.query(`insert into cc_tlog (doc_id, txid, slot, u)
      select l.doc_id, l.txid, ${slot}, l.u from cc_tlog_${old} l join cc_tdoc d on ${UNFOLDED('l')}`)
    await c.query(`truncate cc_tlog_${old}`)
    await c.query('update cc_rot set slot = $1', [old])
    await c.query('commit')
    rotations++
  } catch (e) {
    await c.query('rollback')
    if (e.code !== '55P03') throw e // lock_not_available: try again later
  }
}
const clockSum = (bytes) => [...Y.decodeStateVector(Y.encodeStateVector(docFrom(bytes))).values()].reduce((a, b) => a + b, 0)

async function write (c, id, mine, batched) {
  for (let i = 0; i < mine.length;) {
    const n = batched ? 1 + Math.floor(r.rand() * 4) : 1
    if (n > 1) await c.query('begin')
    for (const u of mine.slice(i, i + n)) {
      const b = Buffer.from(u)
      await c.query('update cc_doc set body = ydoc_apply(body, $2) where id = $1', [id, b])
      await c.query('insert into cc_log (doc_id, u) values ($1, $2)', [id, b])
      await c.query('insert into cc_tlog (doc_id, slot, u) values ($1, (select slot from cc_rot), $2)', [id, b])
    }
    if (n > 1) await c.query('commit')
    i += n
  }
}

let failures = 0
let compactions = 0
let reads = 0
const t0 = performance.now()
for (let round = 0; round < ROUNDS; round++) {
  const id = round
  const { updates, expected } = session(r, PEERS, STEPS)
  const order = r.shuffle(updates.concat(updates.filter(() => r.rand() < 0.1)))
  await admin.query('insert into cc_doc values ($1, null)', [id])
  await admin.query('insert into cc_snap values ($1, ydoc())', [id])
  await admin.query('insert into cc_tdoc values ($1, ydoc(), null)', [id])

  let writing = true
  let regressed = 0
  let tRegressed = 0
  const work = writers.map((c, w) => write(c, id, order.filter((_, i) => i % WRITERS === w), w % 2 === 1))
  const compacting = (async () => {
    while (writing) {
      await compactor.query(COMPACT, [id])
      await compactor.query(T_COMPACT, [id])
      compactions++
    }
  })()
  const reading = (async () => {
    let last = 0
    let tLast = 0
    while (writing) {
      const b = (await reader.query(READ, [id])).rows[0].b
      const sum = clockSum(b)
      if (sum < last) regressed++
      last = sum
      const tb = (await reader.query(T_READ, [id])).rows[0].b
      const tSum = clockSum(tb)
      if (tSum < tLast) tRegressed++
      tLast = tSum
      reads++
    }
  })()
  const rotating = (async () => {
    while (writing) {
      await rotate(rotator)
      await new Promise((resolve) => setTimeout(resolve, 2))
    }
  })()
  try {
    await Promise.all(work)
  } finally {
    writing = false
    await Promise.all([compacting, reading, rotating])
  }

  const row = (await admin.query(`select d.body::bytea doc, ydoc_has_pending(d.body) doc_pending, (${READ}) logged
                                    from cc_doc d where d.id = $1`, [id])).rows[0]
  await admin.query(COMPACT, [id])
  const snap = (await admin.query(`select body::bytea b, ydoc_has_pending(body) p,
    (select count(*) from cc_log where doc_id = $1)::int n from cc_snap where id = $1`, [id])).rows[0]
  const tLogged = (await admin.query(T_READ, [id])).rows[0].b
  await rotate(admin)
  await rotate(admin)
  await admin.query(T_COMPACT, [id])
  await rotate(admin)
  await rotate(admin)
  const tSnap = (await admin.query(`select d.body::bytea b, ydoc_has_pending(d.body) p,
    (select count(*) from cc_tlog l where ${UNFOLDED('l')})::int n, (select count(*) from cc_tlog)::int left
    from cc_tdoc d where d.id = $1`, [id])).rows[0]
  const checks = {
    mergedDoc: !row.doc_pending && canon(snapshotOf(docFrom(row.doc))) === canon(expected),
    snapshotLog: canon(snapshotOf(docFrom(row.logged))) === canon(expected),
    compactedClean: snap.n === 0 && !snap.p && canon(snapshotOf(docFrom(snap.b))) === canon(expected),
    readsNeverRegress: regressed === 0,
    truncateLog: canon(snapshotOf(docFrom(tLogged))) === canon(expected),
    truncateCompactedClean: tSnap.n === 0 && tSnap.left === 0 && !tSnap.p && canon(snapshotOf(docFrom(tSnap.b))) === canon(expected),
    truncateReadsNeverRegress: tRegressed === 0
  }
  const bad = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k)
  if (bad.length) {
    failures++
    console.log(`round ${round}: FAILED ${bad.join(', ')} (${order.length} updates)`)
  }
}
const ms = performance.now() - t0
console.log(`${ROUNDS - failures}/${ROUNDS} rounds converged (seed ${firstSeed}, ${WRITERS} writers, ${PEERS} peers,` +
  ` ${STEPS} steps, ${compactions} concurrent compactions, ${reads} concurrent reads, ${rotations} rotations) in ${(ms / 1000).toFixed(1)}s`)
await admin.query('drop table cc_doc, cc_log, cc_snap, cc_tdoc, cc_tlog, cc_rot')
for (const c of [...writers, compactor, reader, rotator, admin]) await c.end()
process.exit(failures ? 1 : 0)
