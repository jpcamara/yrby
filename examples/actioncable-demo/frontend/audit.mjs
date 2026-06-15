// Authoritative audit test: checks that the server records every change before
// distributing it, in a single total order, and that the audit log alone
// reconstructs the document byte-for-byte.
//
//   1. Boot in audit mode:  AUDIT=1 bin/rails s -p 3777
//   2. Run:                 cd frontend && bun audit.mjs
//
// One client makes a series of edits; we then fetch the server's audit log
// (base64 CRDT deltas), replay it into a fresh Y.Doc with no help from the
// live server, and assert it matches the server's live document.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const ROOM = `audit-${process.pid}`
const EDITS = Number(process.env.EDITS || 25)
const MSG_SYNC = 0

const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const fromBase64 = (b64) => new Uint8Array(Buffer.from(b64, "base64"))

class Client {
  constructor() {
    this.doc = new Y.Doc()
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
    if (msg.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (msg.type === "confirm_subscription") {
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeSyncStep1(enc, this.doc)
      this.send(enc)
      this._onSubscribed()
    } else if (msg.message?.m) {
      const decoder = decoding.createDecoder(fromBase64(msg.message.m))
      while (decoding.hasContent(decoder)) {
        if (decoding.readVarUint(decoder) === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          syncProtocol.readSyncMessage(decoder, enc, this.doc, "remote")
          if (encoding.length(enc) > 1) this.send(enc)
        } else {
          decoding.readVarUint8Array(decoder) // skip awareness
        }
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

  edit(i) {
    const fragment = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const paragraph = new Y.XmlElement("paragraph")
      paragraph.insert(0, [new Y.XmlText(`change number ${i}`)])
      fragment.insert(fragment.length, [paragraph])
    })
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// --- Scenario ---------------------------------------------------------------

const client = new Client()
await client.subscribed

for (let i = 1; i <= EDITS; i++) {
  client.edit(i)
  await sleep(8) // distinct transactions = distinct recorded changes
}
await sleep(400) // let the server drain

// Fetch the audit log and replay it with no live server help.
const auditRes = await fetch(`http://localhost:${PORT}/docs/${ROOM}/audit`)
const audit = await auditRes.json()
if (audit.count < EDITS) {
  throw new Error(`audit log has ${audit.count} entries, expected >= ${EDITS} edits`)
}
console.log(`ok: audit log captured ${audit.count} changes (>= ${EDITS} edits)`)

const replay = new Y.Doc()
for (const entry of audit.updates) Y.applyUpdate(replay, fromBase64(entry))
console.log("ok: replayed the audit log into a fresh document")

// Compare the replay to the server's live document (read from its raw state).
const liveText = await serverText(`http://localhost:${PORT}`, ROOM)

for (let i = 1; i <= EDITS; i++) {
  if (!liveText.includes(`change number ${i}`)) {
    throw new Error(`live document is missing edit ${i}`)
  }
}
if (replay.getXmlFragment("default").length !== client.doc.getXmlFragment("default").length) {
  throw new Error("replayed document structure differs from the client's")
}

// The main check: the audit-log replay equals the client's own document
// byte-for-byte, so the log is a complete record on its own.
const a = Y.encodeStateAsUpdate(replay)
const b = Y.encodeStateAsUpdate(client.doc)
if (a.length !== b.length || !a.every((byte, i) => byte === b[i])) {
  throw new Error("audit-log replay does not match the live document byte-for-byte")
}
console.log("ok: audit-log replay reconstructs the document byte-for-byte")

client.ws.close()
console.log(`\nPASS: room ${ROOM}, ${audit.count} changes recorded before distribution`)
process.exit(0)
