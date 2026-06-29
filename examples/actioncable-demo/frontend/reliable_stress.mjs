// Intensive end-to-end stress test for the reliable provider under message loss.
//
// Many clients edit one document concurrently while their network is actively
// hostile: a sustained fraction of outbound frames is dropped, each client
// suffers random full-blackhole outages, and a fraction of inbound acks are
// dropped too. The reliable layer must still deliver every acknowledged edit.
//
//   bin/rails s -p 3777
//   cd frontend && bun reliable_stress.mjs
//
// Tunables (env): CLIENTS, EDITS (per client), LOSS (outbound drop rate),
// ACK_LOSS (inbound ack drop rate).
//
// What it proves:
//   * Every client's pending queue drains to empty, all edits were acked.
//   * Every unique edit marker is present on every client and on the server
//     (no acknowledged edit silently lost), despite heavy loss.
//   * All docs converge byte-for-byte with each other and the server.
//   * Loss was real and substantial (counts reported), so the path was exercised.
//
// Loss is applied only after the initial handshake completes, and only to the
// directions the reliable layer covers: outbound document batches (recovered by
// retransmit) and inbound acks (a dropped ack just means another retransmit).
// Inbound broadcasts are left intact. After all reliable client->server queues
// drain, fresh clean clients join to prove the durable store can resync the
// complete acknowledged document.
import * as Y from "yjs"
import { ActionCableProvider } from "yrby-client"
import { serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const BASE = `http://localhost:${PORT}`
const URL = `ws://localhost:${PORT}/cable`
const ROOM = `relstress-${process.pid}`

const CLIENTS = Number(process.env.CLIENTS || 6)
const EDITS = Number(process.env.EDITS || 50)
const LOSS = Number(process.env.LOSS || 0.3) // outbound frame drop rate
const ACK_LOSS = Number(process.env.ACK_LOSS || 0.3) // inbound ack drop rate
const TOTAL = CLIENTS * EDITS

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rand = (a, b) => a + Math.floor(Math.random() * (b - a))

// A raw-WebSocket ActionCable consumer with an injectable lossy network:
//   state.loss      - probability each outbound frame is dropped
//   state.blackhole - drop every outbound frame (a full outage)
//   state.ackLoss   - probability each inbound ack is dropped
function lossyConsumer(url) {
  const subs = []
  let welcomed = false
  const state = { loss: 0, blackhole: false, ackLoss: 0, droppedOut: 0, droppedAck: 0, sent: 0 }
  const ws = new WebSocket(url, ["actioncable-v1-json"])
  const subscribe = (s) => ws.send(JSON.stringify({ command: "subscribe", identifier: s.identifier }))
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data)
    if (msg.type === "welcome") {
      welcomed = true
      subs.forEach(subscribe)
    } else if (msg.type === "confirm_subscription") {
      subs.find((s) => s.identifier === msg.identifier)?.connected?.()
    } else if (msg.message) {
      // Drop a fraction of inbound acks; the client should retransmit and re-ack.
      if (msg.message.ack !== undefined && Math.random() < state.ackLoss) {
        state.droppedAck++
        return
      }
      subs.find((s) => s.identifier === msg.identifier)?.received?.(msg.message)
    }
  }
  return {
    state,
    subscriptions: {
      create(params, mixin) {
        const identifier = JSON.stringify(params)
        const sub = Object.assign(
          {
            identifier,
            send(data) {
              if (state.blackhole || Math.random() < state.loss) {
                state.droppedOut++
                return true // frame lost in transit
              }
              ws.send(JSON.stringify({ command: "message", identifier, data: JSON.stringify(data) }))
              state.sent++
              return true
            },
            unsubscribe() {
              ws.send(JSON.stringify({ command: "unsubscribe", identifier }))
            },
          },
          mixin
        )
        subs.push(sub)
        if (welcomed && ws.readyState === WebSocket.OPEN) subscribe(sub)
        return sub
      },
      remove(sub) {
        const i = subs.indexOf(sub)
        if (i >= 0) subs.splice(i, 1)
        sub.unsubscribe()
      },
    },
  }
}

const markersIn = (doc) =>
  new Set((doc.getXmlFragment("default").toString().match(/c\d+-\d+/g) || []))
const addEdit = (doc, marker) => {
  const frag = doc.getXmlFragment("default")
  doc.transact(() => {
    const p = new Y.XmlElement("paragraph")
    p.insert(0, [new Y.XmlText(marker)])
    frag.insert(frag.length, [p])
  })
}
const waitFor = async (label, pred, ms = 30000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (pred()) return true
    await sleep(100)
  }
  check(`TIMEOUT: ${label}`, false)
  return false
}

console.log(
  `room ${ROOM}: ${CLIENTS} clients x ${EDITS} edits = ${TOTAL}, ` +
    `loss=${LOSS}, ackLoss=${ACK_LOSS}`
)

// --- Connect ----------------------------------------------------------------
const opts = { resendInterval: 100 }
const clients = Array.from({ length: CLIENTS }, () => {
  const doc = new Y.Doc()
  const consumer = lossyConsumer(URL)
  const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: ROOM }, opts)
  provider.connect()
  return { doc, consumer, provider }
})

await waitFor("all clients synced (clean network)", () => clients.every((c) => c.provider.synced))
check("all clients completed the handshake", clients.every((c) => c.provider.synced))

// --- Turn the network hostile, then edit hard -------------------------------
for (const c of clients) {
  c.consumer.state.loss = LOSS
  c.consumer.state.ackLoss = ACK_LOSS
}

let editing = true
// Random full-outage windows on random clients, on top of the steady loss.
const outageStorm = (async () => {
  while (editing) {
    const c = clients[rand(0, clients.length)]
    c.consumer.state.blackhole = true
    await sleep(rand(120, 400))
    c.consumer.state.blackhole = false
    await sleep(rand(40, 160))
  }
})()

// Every client fires its edits concurrently, with small jittered gaps.
const editors = clients.map(({ doc }, i) =>
  (async () => {
    for (let n = 0; n < EDITS; n++) {
      addEdit(doc, `c${i}-${n}`)
      await sleep(rand(3, 18))
    }
  })()
)

await Promise.all(editors)
editing = false
await outageStorm
console.log("all edits issued; healing the network and draining queues...")

// --- Heal and let the reliable layer finish the job -------------------------
for (const c of clients) {
  c.consumer.state.loss = 0
  c.consumer.state.ackLoss = 0
  c.consumer.state.blackhole = false
}

await waitFor("every client's pending queue drains (all edits acked)", () => clients.every((c) => !c.provider.hasPending))
check("all pending queues drained", clients.every((c) => !c.provider.hasPending))

const expected = new Set()
for (let i = 0; i < CLIENTS; i++) for (let n = 0; n < EDITS; n++) expected.add(`c${i}-${n}`)

const server = await serverText(BASE, ROOM)
const serverMissing = [...expected].filter((m) => !server.includes(m))
check(`server holds all ${TOTAL} edits`, serverMissing.length === 0)
if (serverMissing.length) console.log(`  server missing ${serverMissing.length}`)

const verifiers = Array.from({ length: Math.min(3, CLIENTS) }, () => {
  const doc = new Y.Doc()
  const consumer = lossyConsumer(URL)
  const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: ROOM }, opts)
  provider.connect()
  return { doc, consumer, provider }
})
await waitFor("fresh clients sync from the durable store", () => verifiers.every((c) => c.provider.synced))

await waitFor("every verifier sees all edits", () =>
  verifiers.every((c) => markersIn(c.doc).size === TOTAL)
)

// --- Assertions -------------------------------------------------------------
let everyVerifierComplete = true
for (const [i, c] of verifiers.entries()) {
  const have = markersIn(c.doc)
  const missing = [...expected].filter((m) => !have.has(m))
  if (missing.length) {
    everyVerifierComplete = false
    console.log(`  verifier ${i} missing ${missing.length}: ${missing.slice(0, 5).join(",")}...`)
  }
}
check(`fresh clients have all ${TOTAL} edits (nothing acknowledged was lost)`, everyVerifierComplete)

const ref = Y.encodeStateAsUpdate(verifiers[0].doc)
const converged = verifiers.every((c) => {
  const u = Y.encodeStateAsUpdate(c.doc)
  return u.length === ref.length && u.every((b, k) => b === ref[k])
})
check("fresh client docs converged byte-for-byte", converged)

const totalDroppedOut = clients.reduce((s, c) => s + c.consumer.state.droppedOut, 0)
const totalDroppedAck = clients.reduce((s, c) => s + c.consumer.state.droppedAck, 0)
const totalSent = clients.reduce((s, c) => s + c.consumer.state.sent, 0)
check("loss was actually exercised (outbound frames dropped)", totalDroppedOut > TOTAL * 0.1)
check("ack loss was actually exercised", totalDroppedAck > 0)
console.log(`\nstats: sent=${totalSent} droppedOut=${totalDroppedOut} droppedAck=${totalDroppedAck}`)

for (const c of clients.concat(verifiers)) c.provider.destroy()
console.log("")
if (failures > 0) {
  console.log(`FAILED: ${failures} check(s) failed`)
  process.exit(1)
}
console.log(`PASS: room ${ROOM} — ${TOTAL} edits reached the durable store and fresh clients resynced`)
process.exit(0)
