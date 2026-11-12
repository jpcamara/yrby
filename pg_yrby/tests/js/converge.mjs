// Convergence: random concurrent edits in JS Yjs, every update pushed into
// Postgres in shuffled order, and the result compared with the JS peers.
//
// Each round, PEERS Yjs docs make random edits (text with UTF-16 surrogate
// pairs, map sets, array pushes and deletes) and sync with each other now and
// then, so updates depend on other peers' updates. Postgres then receives
// every update in a random order, which parks many of them as pending until
// their dependencies arrive. Three paths must all match the JS state:
//   1. ydoc_apply, one update per statement, into a ydoc column
//   2. ydoc_merge_agg over the shuffled updates
//   3. a snapshot + log table, compacted at random points
// plus ydoc_diff syncing a stale JS peer up to date.
//
// Usage: node converge.mjs   Env: ROUNDS (30), PEERS (4), STEPS (60), SEED, PGPORT (28817)
import pg from 'pg'
import * as Y from 'yjs'
import fs from 'node:fs'
import { canon, docFrom, rng, session, snapshotOf, svMap } from './session.mjs'

const ROUNDS = Number(process.env.ROUNDS ?? 30)
const PEERS = Number(process.env.PEERS ?? 4)
const STEPS = Number(process.env.STEPS ?? 60)
const firstSeed = Number(process.env.SEED ?? Date.now() % 1e9)
const r = rng(firstSeed)
const { rand, shuffle } = r

const c = new pg.Client({ host: 'localhost', port: Number(process.env.PGPORT ?? 28817), database: 'postgres' })
await c.connect()
await c.query('create extension if not exists pg_yrby')
await c.query('drop table if exists conv_doc, conv_log, conv_snap')
await c.query('create table conv_doc (id int primary key, body ydoc)')
await c.query('create table conv_snap (id int primary key, body ydoc)')
await c.query('create table conv_log (id bigserial primary key, doc_id int not null, u bytea not null)')

// Fold the whole log into the snapshot and delete what was folded, in one
// statement. Pending content waits inside the snapshot.
async function compact (id) {
  await c.query(`
    with folded as (delete from conv_log where doc_id = $1 returning u)
    update conv_snap set body = ydoc_apply(body, (select ydoc_merge_agg(u)::bytea from folded))
     where id = $1`, [id])
  compactions++
}

let failures = 0
let maxPending = 0
let compactions = 0
const t0 = performance.now()
for (let round = 0; round < ROUNDS; round++) {
  // A stale peer that only sees the first third, to test ydoc_diff later.
  const stale = new Y.Doc()
  const { peers, updates, expected } = session(r, PEERS, STEPS, (s, sofar) => {
    if (s === Math.floor(STEPS / 3)) for (const u of sofar) Y.applyUpdate(stale, u)
  })
  const expectedSv = svMap(Y.encodeStateVector(peers[0]))

  const id = round
  // Shuffled, with about 10% delivered twice (a retry after a lost ack).
  const order = shuffle(updates.concat(updates.filter(() => rand() < 0.1)))
  // 1. ydoc_apply, one statement per update, shuffled.
  await c.query('insert into conv_doc values ($1, null)', [id])
  // A JS peer joins partway through, served pending content too
  // (include_pending), and then receives only the updates after that point.
  const joinAt = Math.floor(rand() * order.length)
  let joiner
  for (const [i, u] of order.entries()) {
    await c.query('update conv_doc set body = ydoc_apply(body, $2) where id = $1', [id, Buffer.from(u)])
    const st = (await c.query('select ydoc_has_pending(body) p, case when $2 then ydoc_diff(body, null, true) end j from conv_doc where id = $1', [id, i === joinAt])).rows[0]
    if (st.p) maxPending++
    if (i === joinAt) joiner = docFrom(st.j)
  }
  for (const u of order.slice(joinAt + 1)) Y.applyUpdate(joiner, u)
  // 3. snapshot + log, compacted at random points.
  await c.query('insert into conv_snap values ($1, ydoc())', [id])
  for (const u of shuffle(updates.concat(updates.filter(() => rand() < 0.1)))) {
    await c.query('insert into conv_log (doc_id, u) values ($1, $2)', [id, Buffer.from(u)])
    if (rand() < 0.1) await compact(id)
  }

  const row = (await c.query(`
    select ydoc_text(d.body, 'body') body, ydoc_map(d.body, 'meta') meta, ydoc_array(d.body, 'list') list,
           ydoc_has_pending(d.body) pending, ydoc_state_vector(d.body) sv, ydoc_diff(d.body) full_diff,
           ydoc_diff(d.body, $2) stale_diff,
           (select ydoc_merge_agg(u)::bytea from unnest($3::bytea[]) u) merged,
           (select ydoc_merge_agg(x)::bytea from (select body::bytea x from conv_snap where id = $1
                                                   union all select u from conv_log where doc_id = $1) t) logged
      from conv_doc d where d.id = $1`,
  [id, Buffer.from(Y.encodeStateVector(stale)), shuffle(updates).map((u) => Buffer.from(u))])).rows[0]

  const checks = {
    apply: canon({ body: row.body, meta: row.meta ?? {}, list: row.list ?? [] }) === canon(expected),
    noPending: row.pending === false,
    stateVector: svMap(row.sv) === expectedSv,
    fullDiff: canon(snapshotOf(docFrom(row.full_diff))) === canon(expected),
    staleDiff: (() => { Y.applyUpdate(stale, row.stale_diff); return canon(snapshotOf(stale)) === canon(expected) })(),
    mergeAgg: canon(snapshotOf(docFrom(row.merged))) === canon(expected),
    snapshotLog: canon(snapshotOf(docFrom(row.logged))) === canon(expected),
    midJoinWithPending: canon(snapshotOf(joiner)) === canon(expected)
  }
  // Fold the rest of the log; a complete log must leave nothing behind.
  await compact(id)
  const snap = (await c.query(`select body::bytea b, ydoc_has_pending(body) p,
    (select count(*) from conv_log where doc_id = $1)::int n from conv_snap where id = $1`, [id])).rows[0]
  checks.compactedClean = snap.n === 0 && !snap.p && canon(snapshotOf(docFrom(snap.b))) === canon(expected)
  const bad = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k)
  if (bad.length) {
    failures++
    console.log(`round ${round}: FAILED ${bad.join(', ')} (${updates.length} updates)`)
    if (process.env.DUMP) {
      // The ydoc_apply order, one hex update per line, for reproducing in Rust.
      fs.mkdirSync(process.env.DUMP, { recursive: true })
      fs.writeFileSync(`${process.env.DUMP}/round-${round}.hex`, order.map((u) => Buffer.from(u).toString('hex')).join('\n') + '\n')
      fs.writeFileSync(`${process.env.DUMP}/round-${round}.json`, canon(expected))
    }
  }
}
const ms = performance.now() - t0
console.log(`${ROUNDS - failures}/${ROUNDS} rounds converged (seed ${firstSeed}, ${PEERS} peers, ${STEPS} steps,` +
  ` ${maxPending} intermediate states with pending, ${compactions} compactions) in ${(ms / 1000).toFixed(1)}s`)
await c.query('drop table conv_doc, conv_log, conv_snap')
await c.end()
process.exit(failures ? 1 : 0)
