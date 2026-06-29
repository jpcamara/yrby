// Drives yrby-client's ActionCableProvider against the yrby server,
// headless. Two checks:
//
//   1. Two providers sync documents + presence through the canonical yrby
//      envelopes.
//   2. Reliability: a silently-lost client->server batch is recovered by the
//      provider's own retransmit, no reconnect, no follow-up edit, and the
//      ack drains its pending queue.
//
//   bin/rails s -p 3777
//   cd frontend && bun reliable_provider.mjs
//
// We hand the provider a minimal raw-WebSocket ActionCable consumer. The
// consumer has a `blackhole` switch that drops outbound frames without tearing
// down the socket, a lost-in-transit network, not a disconnect, so the
// provider keeps retransmitting on its timer.
import * as Y from "yjs"
import { ActionCableProvider } from "yrby-client"

const PORT = process.env.PORT || 3777
const ROOM = `relprov-${process.pid}`
const URL = `ws://localhost:${PORT}/cable`

// Minimal ActionCable consumer over a raw WebSocket, with a network blackhole.
function rawConsumer(url) {
  const subs = []
  let welcomed = false
  const state = { blackhole: false, dropped: 0 }
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
              if (state.blackhole) {
                state.dropped++ // simulate a frame lost in transit
                return true
              }
              ws.send(JSON.stringify({ command: "message", identifier, data: JSON.stringify(data) }))
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
        sub.unsubscribe()
      },
    },
  }
}

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const waitFor = async (label, pred, ms = 5000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (pred()) return true
    await sleep(50)
  }
  check(`TIMEOUT: ${label}`, false)
  return false
}
const stayFalse = async (label, pred, ms = 600) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (pred()) {
      check(`${label} (unexpectedly true)`, false)
      return false
    }
    await sleep(50)
  }
  return true
}
const addParagraph = (doc, t) => {
  const frag = doc.getXmlFragment("default")
  doc.transact(() => {
    const p = new Y.XmlElement("paragraph")
    p.insert(0, [new Y.XmlText(t)])
    frag.insert(frag.length, [p])
  })
}
const text = (doc) => doc.getXmlFragment("default").toString()

const opts = { resendInterval: 150 }
const doc1 = new Y.Doc()
const doc2 = new Y.Doc()
const c1 = rawConsumer(URL)
const p1 = new ActionCableProvider(doc1, c1, "DocumentChannel", { id: ROOM }, opts)
const p2 = new ActionCableProvider(doc2, rawConsumer(URL), "DocumentChannel", { id: ROOM }, opts)
p1.connect()
p2.connect()

await waitFor("both providers report synced", () => p1.synced && p2.synced)
check("both providers synced with the server", p1.synced && p2.synced)

// 1. Normal edit: propagates, gets acked, drains p1's pending queue.
addParagraph(doc1, "alpha")
await waitFor("p2 receives alpha", () => text(doc2).includes("alpha"))
await waitFor("p1's queue drains (alpha acked)", () => !p1.hasPending)
check("normal edit acked and propagated", text(doc2).includes("alpha") && !p1.hasPending)

// 2. Network blackhole: p1's next batch (and every retransmit) is dropped before
//    reaching the server. Nothing else is sent, so the server stays idle and
//    never asks anyone to resync, a plain provider would lose this edit.
c1.state.blackhole = true
addParagraph(doc1, "beta-lost")

const absent = await stayFalse("beta-lost stays off p2 during the outage", () =>
  text(doc2).includes("beta-lost")
)
check("lost edit did not reach p2 during the outage", absent)
check("p1 still has the edit queued (unacked)", p1.hasPending)
check("the provider kept retransmitting (and failing)", c1.state.dropped >= 2)

// 3. Connectivity returns: the next retransmit lands, the server acks, and the
//    edit propagates. Recovery is driven purely by the provider's retransmit.
c1.state.blackhole = false
await waitFor("p1's queue drains once connectivity returns", () => !p1.hasPending)
await waitFor("p2 receives the recovered beta-lost", () => text(doc2).includes("beta-lost"))
check("retransmit recovered the lost edit", text(doc2).includes("beta-lost") && !p1.hasPending)

// Presence still flows, and the docs converge byte-for-byte.
p1.awareness.setLocalState({ user: { name: "P-ONE" } })
await waitFor("p2 sees p1's presence", () =>
  [...p2.awareness.getStates().values()].some((s) => s.user?.name === "P-ONE")
)
check("awareness propagated", [...p2.awareness.getStates().values()].some((s) => s.user?.name === "P-ONE"))

await sleep(200)
const a = Y.encodeStateAsUpdate(doc1)
const b = Y.encodeStateAsUpdate(doc2)
check("documents converged byte-for-byte", a.length === b.length && a.every((x, i) => x === b[i]))

p1.destroy()
p2.destroy()
console.log("")
if (failures > 0) {
  console.log(`FAILED: ${failures} check(s) failed`)
  process.exit(1)
}
console.log(`PASS: room ${ROOM} (provider recovered a silently-lost batch via retransmit)`)
process.exit(0)
