// End-to-end test: two simulated Yjs clients sync through the Rails server
// over ActionCable's raw WebSocket protocol, with no browser required.
//
//   1. Boot the Rails server:  bin/rails s -p 3777
//   2. Run:                    cd frontend && bun e2e.mjs
//
// Checks document convergence in both directions, awareness propagation, and
// the server-side content endpoint (the server's CRDT state).
import * as Y from "yjs"
import * as awarenessProtocol from "y-protocols/awareness"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverDoc, serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const ROOM = `e2e-${process.pid}`
const MSG_SYNC = 0
const MSG_AWARENESS = 1

const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const fromBase64 = (b64) => new Uint8Array(Buffer.from(b64, "base64"))

class TestClient {
  constructor(name) {
    this.name = name
    this.doc = new Y.Doc()
    this.awareness = new awarenessProtocol.Awareness(this.doc)
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: ROOM })
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))

    this.doc.on("update", (update, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, update)
      this.send(enc)
    })

    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => this.onMessage(JSON.parse(event.data))
  }

  onMessage(msg) {
    switch (msg.type) {
      case "welcome":
        this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
        return
      case "confirm_subscription": {
        // Announce our state + presence, like the browser provider does.
        const enc = encoding.createEncoder()
        encoding.writeVarUint(enc, MSG_SYNC)
        syncProtocol.writeSyncStep1(enc, this.doc)
        this.send(enc)
        this._onSubscribed()
        return
      }
      case "ping":
      case "disconnect":
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
        if (encoding.length(enc) > 1) this.send(enc)
      } else if (type === MSG_AWARENESS) {
        awarenessProtocol.applyAwarenessUpdate(
          this.awareness,
          decoding.readVarUint8Array(decoder),
          "remote"
        )
      } else {
        throw new Error(`${this.name}: unknown message type ${type}`)
      }
    }
  }

  send(encoder) {
    this.ws.send(
      JSON.stringify({
        command: "message",
        identifier: this.identifier,
        data: JSON.stringify({ m: toBase64(encoding.toUint8Array(encoder)) }),
      })
    )
  }

  setPresence(state) {
    this.awareness.setLocalState(state)
    const enc = encoding.createEncoder()
    encoding.writeVarUint(enc, MSG_AWARENESS)
    encoding.writeVarUint8Array(
      enc,
      awarenessProtocol.encodeAwarenessUpdate(this.awareness, [this.doc.clientID])
    )
    this.send(enc)
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

// --- Scenario ---------------------------------------------------------------

const alice = new TestClient("alice")
await alice.subscribed
alice.insertParagraph("Hello from Alice")
alice.setPresence({ user: { name: "Alice", color: "#f00" } })

// Bob joins late: the server (not Alice) must bring him up to date.
const bob = new TestClient("bob")
await bob.subscribed

await waitFor("bob receives alice's edit via server", () =>
  bob.textContent().includes("Hello from Alice")
)
await waitFor("bob sees alice's presence", () =>
  [...bob.awareness.getStates().values()].some((s) => s.user?.name === "Alice")
)

bob.insertParagraph("Hi from Bob")
await waitFor("alice receives bob's live update", () =>
  alice.textContent().includes("Hi from Bob")
)

await waitFor("docs converge byte-for-byte", () => {
  const a = Y.encodeStateAsUpdate(alice.doc)
  const b = Y.encodeStateAsUpdate(bob.doc)
  return a.length === b.length && a.every((byte, i) => byte === b[i])
})

// Server-side view of the live document (the server's CRDT state).
const { status, doc } = await serverDoc(`http://localhost:${PORT}`, ROOM)
if (status !== 200 || !doc) {
  throw new Error(`content endpoint failed: ${status}`)
}
const serverContent = await serverText(`http://localhost:${PORT}`, ROOM)
if (!serverContent.includes("Hello from Alice") || !serverContent.includes("Hi from Bob")) {
  throw new Error(`server content missing edits: ${serverContent}`)
}
console.log("ok: server-side CRDT state matches both edits")

// Presence reaping: when a client disconnects, the server should clear its
// awareness state and tell the others right away, rather than leaving a ghost
// cursor until the client-side ~30s timeout. Bob takes presence too so we can
// check that only Alice's state is removed.
bob.setPresence({ user: { name: "Bob", color: "#00f" } })
await waitFor("alice sees bob's presence", () =>
  [...alice.awareness.getStates().values()].some((s) => s.user?.name === "Bob")
)

alice.close()
await waitFor(
  "bob sees alice's presence reaped after disconnect (server-driven, <30s)",
  () => ![...bob.awareness.getStates().values()].some((s) => s.user?.name === "Alice"),
  5000
)
if (![...bob.awareness.getStates().values()].some((s) => s.user?.name === "Bob")) {
  throw new Error("bob's own presence was wrongly removed by alice's disconnect")
}
console.log("ok: only the departed client's presence was cleared")

bob.close()
console.log(`\nPASS: room ${ROOM}`)
process.exit(0)
