// Reliable-delivery test: proves a silently-lost client->server update is
// recovered by the client's own retransmit -- no reconnect, no follow-up edit
// to trigger a resync. This is the "fire-and-forget send never reached the
// server" failure that a plain CRDT provider loses forever (the server is idle,
// so it never knows anything is missing and never asks anyone to resync).
//
//   1. Boot the Rails server:  bin/rails s -p 3777   (AUDIT=1 also works)
//   2. Run:                    cd frontend && bun reliable.mjs
//
// The reliable client tags each outgoing update with an incrementing id, keeps
// it in a pending buffer, and retransmits on a timer until the server returns
// `{ ack: <id> }`. Idempotent CRDT apply makes resends free. Stock clients send
// no id, never get acks, and are unaffected.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

const PORT = process.env.PORT || 3777
const ROOM = `reliable-${process.pid}`
const MSG_SYNC = 0
const MSG_AWARENESS = 1

const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const fromBase64 = (b64) => new Uint8Array(Buffer.from(b64, "base64"))

// A minimal ack-aware provider: the reference client of the reliable layer.
class ReliableClient {
  constructor(name, { retransmitMs = 200 } = {}) {
    this.name = name
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: ROOM })
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))

    this.nextId = 1
    this.pending = new Map() // id -> frame bytes, retained until acked
    this.acked = [] // ids the server has acknowledged
    this.blackhole = false // test hook: drop every wire send (models an outage)
    this.dropped = 0

    this.doc.on("update", (update, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, update)
      this.sendReliable(encoding.toUint8Array(enc))
    })

    this.timer = setInterval(() => this.retransmit(), retransmitMs)
    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => this.onMessage(JSON.parse(event.data))
  }

  onMessage(msg) {
    switch (msg.type) {
      case "welcome":
        this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
        return
      case "confirm_subscription": {
        const enc = encoding.createEncoder()
        encoding.writeVarUint(enc, MSG_SYNC)
        syncProtocol.writeSyncStep1(enc, this.doc)
        this.sendRaw(encoding.toUint8Array(enc)) // handshake: no id, no ack expected
        this._onSubscribed()
        return
      }
      case "ping":
      case "disconnect":
        return
    }
    // Reliable-delivery ack: drop the matching update from the pending buffer.
    if (msg.message?.ack !== undefined) {
      this.pending.delete(msg.message.ack)
      this.acked.push(msg.message.ack)
      return
    }
    if (msg.message?.m) this.receiveBinary(fromBase64(msg.message.m))
  }

  receiveBinary(bytes) {
    const decoder = decoding.createDecoder(bytes)
    while (decoding.hasContent(decoder)) {
      const type = decoding.readVarUint(decoder)
      if (type === MSG_SYNC) {
        const enc = encoding.createEncoder()
        encoding.writeVarUint(enc, MSG_SYNC)
        syncProtocol.readSyncMessage(decoder, enc, this.doc, "remote")
        if (encoding.length(enc) > 1) this.sendRaw(encoding.toUint8Array(enc))
      } else if (type === MSG_AWARENESS) {
        decoding.readVarUint8Array(decoder) // ignore presence in this test
      } else {
        throw new Error(`${this.name}: unknown message type ${type}`)
      }
    }
  }

  // Tag an outgoing update with an id and retain it until acked.
  sendReliable(frameBytes) {
    const id = this.nextId++
    this.pending.set(id, frameBytes)
    this.transmit(id, frameBytes)
  }

  // Resend everything still unacked. Free to call repeatedly: the server's CRDT
  // apply is idempotent, so a redundant resend is a no-op that re-acks.
  retransmit() {
    for (const [id, frameBytes] of this.pending) this.transmit(id, frameBytes)
  }

  transmit(id, frameBytes) {
    if (this.blackhole) {
      this.dropped++
      return // simulate lost connectivity: the bytes never reach the server
    }
    this.ws.send(
      JSON.stringify({
        command: "message",
        identifier: this.identifier,
        data: JSON.stringify({ m: toBase64(frameBytes), id }),
      })
    )
  }

  // Protocol traffic with no reliability (handshake, SyncStep2 replies): no id.
  sendRaw(frameBytes) {
    this.ws.send(
      JSON.stringify({
        command: "message",
        identifier: this.identifier,
        data: JSON.stringify({ m: toBase64(frameBytes) }),
      })
    )
  }

  insertParagraph(text) {
    const fragment = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const paragraph = new Y.XmlElement("paragraph")
      paragraph.insert(0, [new Y.XmlText(text)])
      fragment.insert(fragment.length, [paragraph])
    })
  }

  textContent() {
    return this.doc.getXmlFragment("default").toString()
  }

  close() {
    clearInterval(this.timer)
    this.ws.close()
  }
}

const waitFor = async (label, predicate, timeoutMs = 5000) => {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) {
      console.log(`ok: ${label}`)
      return
    }
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`TIMEOUT waiting for: ${label}`)
}

const stayFalse = async (label, predicate, windowMs = 600) => {
  const deadline = Date.now() + windowMs
  while (Date.now() < deadline) {
    if (predicate()) throw new Error(`EXPECTED-ABSENT but present: ${label}`)
    await new Promise((r) => setTimeout(r, 50))
  }
  console.log(`ok: ${label}`)
}

// --- Scenario ---------------------------------------------------------------

const alice = new ReliableClient("alice")
await alice.subscribed

const bob = new ReliableClient("bob")
await bob.subscribed

// 1. A normal edit is acked and drains the pending buffer.
alice.insertParagraph("First edit")
await waitFor("normal edit is acked (pending buffer drains)", () => alice.pending.size === 0)
await waitFor("bob receives the first edit", () =>
  bob.textContent().includes("First edit")
)

// 2. Alice loses connectivity, then edits: the send (and every retransmit) is
//    dropped before reaching the server. Nothing else is sent, so the server
//    stays idle and never asks anyone to resync -- a plain provider would lose
//    this edit permanently.
alice.blackhole = true
alice.insertParagraph("Lost edit")

// While the outage lasts, the edit is buffered and unacked; it never reaches
// the server or Bob, and the retransmit timer keeps trying (and failing).
await stayFalse("lost edit does not reach bob during the outage", () =>
  bob.textContent().includes("Lost edit")
)
if (alice.pending.size === 0) {
  throw new Error("lost edit must still be pending (unacked) during the outage")
}
if (alice.dropped < 2) {
  throw new Error(`retransmit should have retried during the outage, saw ${alice.dropped} drops`)
}
console.log(`ok: the edit is buffered and retried ${alice.dropped}x during the outage (still unacked)`)

// 3. Connectivity returns. The next retransmit reaches the server, which
//    applies, acks, and relays it. Recovery is driven purely by the client
//    retransmit -- no reconnect, no follow-up edit forcing a resync.
alice.blackhole = false
await waitFor("retransmit recovers the lost edit once connectivity returns (acked)",
  () => alice.pending.size === 0)
await waitFor("bob receives the recovered edit", () =>
  bob.textContent().includes("Lost edit")
)

await waitFor("docs converge byte-for-byte", () => {
  const a = Y.encodeStateAsUpdate(alice.doc)
  const b = Y.encodeStateAsUpdate(bob.doc)
  return a.length === b.length && a.every((byte, i) => byte === b[i])
})

if (alice.acked.length < 2) {
  throw new Error(`expected at least 2 acks, saw ${alice.acked.length}`)
}

alice.close()
bob.close()
console.log(`\nPASS: room ${ROOM} (recovered a silently-lost update via retransmit)`)
process.exit(0)
