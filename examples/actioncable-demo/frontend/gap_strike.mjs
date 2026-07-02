// Unhealable-gap strike defense e2e: a poisoned client keeps retransmitting an
// update whose causal dependency is gone for good (cross-client origins the
// server never saw and the client can't supply). The server must resync it
// twice (the heal attempts), then settle it on the third strike with
// `{ ack, dropped: true }` — and never record it. A healable gap (dependency
// arrives) must still record normally with a plain ack.
//
// Runs against BOTH stacks — the wire protocol is identical:
//   Plain ActionCable:  WS_PORT=3777 HTTP_PORT=3777 bun gap_strike.mjs
//   AnyCable:           WS_PORT=8080 HTTP_PORT=3797 bun gap_strike.mjs
// (Under AnyCable the strike table survives the per-command fresh channel
// instance via anycable-rails istate — that's the part this proves.)
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"

const WS_PORT = process.env.WS_PORT || 3777
const HTTP_PORT = process.env.HTTP_PORT || WS_PORT
const MSG_SYNC = 0

const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}

// A cross-client-origin gap: client 3 creates "abc"; client 1 applies it and
// types between client 3's characters. On a server that never saw client 3's
// content, client 1's delta is causally incomplete — and our poisoned client
// never answers the resync (its copy of the dependency is gone), so the gap is
// unhealable.
const buildGap = () => {
  const c = new Y.Doc()
  c.clientID = 3
  c.getText("t").insert(0, "abc")
  const content = Y.encodeStateAsUpdate(c)
  const a = new Y.Doc()
  a.clientID = 1
  Y.applyUpdate(a, content)
  const sv = Y.encodeStateVector(a)
  a.getText("t").insert(1, "X")
  const delta = Y.encodeStateAsUpdate(a, sv)
  return { content, delta }
}

const frameFor = (update) => {
  const enc = encoding.createEncoder()
  encoding.writeVarUint(enc, MSG_SYNC)
  syncProtocol.writeUpdate(enc, update)
  return encoding.toUint8Array(enc)
}

// A deliberately-dumb cable client: sends what it's told, records acks and
// update-envelopes (resyncs), never answers a SyncStep1.
class PoisonedClient {
  constructor(room) {
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.acks = [] // { id, dropped }
    this.updateEnvelopes = 0 // server->client protocol frames (the resyncs)
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))
    this.ws = new WebSocket(`ws://localhost:${WS_PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data)
      if (msg.type === "welcome") {
        this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
      } else if (msg.type === "confirm_subscription") {
        this._onSubscribed()
      } else if (msg.message) {
        if (msg.message.ack !== undefined) {
          this.acks.push({ id: msg.message.ack, dropped: msg.message.dropped === true })
        } else if (typeof msg.message.update === "string") {
          this.updateEnvelopes++ // opening SyncStep1 or a resync
        }
      }
    }
  }

  send(update, id) {
    const data = JSON.stringify({ update: toBase64(frameFor(update)), id })
    this.ws.send(JSON.stringify({ command: "message", identifier: this.identifier, data }))
  }

  close() {
    this.ws.close()
  }
}

// The durable text of a room, rebuilt from the store's replay (/content returns
// { state: base64 }). Empty string when nothing was ever recorded (404).
const content = async (room) => {
  const res = await fetch(`http://localhost:${HTTP_PORT}/docs/${room}/content`)
  if (!res.ok) return ""
  const { state } = await res.json()
  const doc = new Y.Doc()
  Y.applyUpdate(doc, new Uint8Array(Buffer.from(state, "base64")))
  return doc.getText("t").toString()
}

// --- Scenario 1: an unhealable gap strikes out and is settled + dropped ---
{
  const room = `strike-${process.pid}`
  const { delta } = buildGap()
  const client = new PoisonedClient(room)
  await client.subscribed
  await sleep(300)
  const baselineEnvelopes = client.updateEnvelopes // the opening SyncStep1

  for (let id = 1; id <= 3; id++) {
    client.send(delta, id)
    await sleep(500)
  }

  const resyncs = client.updateEnvelopes - baselineEnvelopes
  check("strikes 1+2 each triggered a resync (2 total)", resyncs === 2)
  check("strikes 1+2 were not acked", !client.acks.some((a) => a.id === 1 || a.id === 2))
  const settled = client.acks.find((a) => a.id === 3)
  check("strike 3 was settled with an ack", !!settled)
  check("the settle is marked dropped", settled?.dropped === true)
  const body = await content(room)
  check("the unhealable update was never recorded", !body.includes("X"))
  client.close()
}

// --- Scenario 2: a healable gap still heals and records with a plain ack ---
{
  const room = `heal-${process.pid}`
  const { content: dep, delta } = buildGap()
  const client = new PoisonedClient(room)
  await client.subscribed
  await sleep(300)

  client.send(delta, 1) // gappy: strike 1 -> resync, no ack
  await sleep(500)
  client.send(dep, 2) // the missing dependency arrives ("the heal")
  await sleep(500)
  client.send(delta, 3) // now ready: records
  await sleep(500)

  check("the gappy first attempt was not acked", !client.acks.some((a) => a.id === 1))
  const depAck = client.acks.find((a) => a.id === 2)
  const deltaAck = client.acks.find((a) => a.id === 3)
  check("the dependency recorded with a plain ack", !!depAck && depAck.dropped === false)
  check("the healed delta recorded with a plain ack (not dropped)", !!deltaAck && deltaAck.dropped === false)
  const body = await content(room)
  check("the healed content is durable (aXbc)", body.includes("aXbc"))
  client.close()
}

if (failures > 0) {
  console.log(`FAIL: ${failures} check(s) failed`)
  process.exit(1)
}
console.log("PASS: unhealable gaps strike out (settled + dropped); healable gaps still record")
process.exit(0)
