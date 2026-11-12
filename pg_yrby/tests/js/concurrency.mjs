// Concurrency: many connections writing the same document at once.
//
// Each round, a random Yjs session's updates (shuffled, about 10% sent twice)
// are split across WRITERS connections that run at the same time. Every
// writer applies each update to one merged ydoc row and appends it to a
// snapshot + log pair; some writers wrap a few updates in one transaction.
// Meanwhile one connection compacts the log over and over, and another reads
// the snapshot + log and checks that the state vector never goes backwards (a
// compaction that is not atomic would show a read missing folded rows).
// At the end both stores must match the JS peers, with nothing pending.
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
await admin.query('create extension if not exists pg_yrby')
await admin.query('drop table if exists cc_doc, cc_log, cc_snap')
await admin.query('create table cc_doc (id int primary key, body ydoc)')
await admin.query('create table cc_snap (id int primary key, body ydoc not null)')
await admin.query('create table cc_log (id bigserial primary key, doc_id int not null, u bytea not null)')
await admin.query('create index on cc_log (doc_id, id)')
const writers = await Promise.all(Array.from({ length: WRITERS }, connect))
const compactor = await connect()
const reader = await connect()

const COMPACT = `
  with folded as (delete from cc_log where doc_id = $1 returning u)
  update cc_snap set body = ydoc_apply(body, (select ydoc_merge_agg(u)::bytea from folded))
   where id = $1`
const READ = `
  select ydoc_merge_agg(x)::bytea b from (
    select body::bytea x from cc_snap where id = $1
    union all select u from cc_log where doc_id = $1) t`
const clockSum = (bytes) => [...Y.decodeStateVector(Y.encodeStateVectorFromUpdate(bytes)).values()].reduce((a, b) => a + b, 0)

async function write (c, id, mine, batched) {
  for (let i = 0; i < mine.length;) {
    const n = batched ? 1 + Math.floor(r.rand() * 4) : 1
    if (n > 1) await c.query('begin')
    for (const u of mine.slice(i, i + n)) {
      const b = Buffer.from(u)
      await c.query('update cc_doc set body = ydoc_apply(body, $2) where id = $1', [id, b])
      await c.query('insert into cc_log (doc_id, u) values ($1, $2)', [id, b])
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

  let writing = true
  let regressed = 0
  const work = writers.map((c, w) => write(c, id, order.filter((_, i) => i % WRITERS === w), w % 2 === 1))
  const compacting = (async () => {
    while (writing) {
      await compactor.query(COMPACT, [id])
      compactions++
    }
  })()
  const reading = (async () => {
    let last = 0
    while (writing) {
      const b = (await reader.query(READ, [id])).rows[0].b
      const sum = clockSum(b)
      if (sum < last) regressed++
      last = sum
      reads++
    }
  })()
  try {
    await Promise.all(work)
  } finally {
    writing = false
    await Promise.all([compacting, reading])
  }

  const row = (await admin.query(`select d.body::bytea doc, ydoc_has_pending(d.body) doc_pending, (${READ}) logged
                                    from cc_doc d where d.id = $1`, [id])).rows[0]
  await admin.query(COMPACT, [id])
  const snap = (await admin.query(`select body::bytea b, ydoc_has_pending(body) p,
    (select count(*) from cc_log where doc_id = $1)::int n from cc_snap where id = $1`, [id])).rows[0]
  const checks = {
    mergedDoc: !row.doc_pending && canon(snapshotOf(docFrom(row.doc))) === canon(expected),
    snapshotLog: canon(snapshotOf(docFrom(row.logged))) === canon(expected),
    compactedClean: snap.n === 0 && !snap.p && canon(snapshotOf(docFrom(snap.b))) === canon(expected),
    readsNeverRegress: regressed === 0
  }
  const bad = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k)
  if (bad.length) {
    failures++
    console.log(`round ${round}: FAILED ${bad.join(', ')} (${order.length} updates)`)
  }
}
const ms = performance.now() - t0
console.log(`${ROUNDS - failures}/${ROUNDS} rounds converged (seed ${firstSeed}, ${WRITERS} writers, ${PEERS} peers,` +
  ` ${STEPS} steps, ${compactions} concurrent compactions, ${reads} concurrent reads) in ${(ms / 1000).toFixed(1)}s`)
await admin.query('drop table cc_doc, cc_log, cc_snap')
for (const c of [...writers, compactor, reader, admin]) await c.end()
process.exit(failures ? 1 : 0)
