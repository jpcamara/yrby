// Crash-recovery durability test. Run in two phases around a hard `kill -9`
// of the server (the manual flow in the demo README's crash-recovery section):
//
//   PHASE=write  ROOM=... bun crash_recovery.mjs   # make edits, wait until logged
//   <SIGKILL the server, restart it>
//   PHASE=verify ROOM=... bun crash_recovery.mjs   # check nothing was lost
//
// The file store fsyncs every change before it is broadcast, so every
// acknowledged edit is on disk when the server dies. On restart, on_load
// replays the log and the document comes back whole, without the loss window a
// debounced-persistence server would have.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const ROOM = process.env.ROOM || `crash-${process.pid}`
const PHASE = process.env.PHASE || "write"
const EDITS = Number(process.env.EDITS || 30)
const MSG_SYNC = 0

const toBase64 = (b) => Buffer.from(b).toString("base64")
const fromBase64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

class Client {
  constructor(room) {
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.synced = new Promise((r) => (this._syn = r))
    this.doc.on("update", (update, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, update)
      this._send(enc)
    })
    this.ws = new WebSocket(`ws://127.0.0.1:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (e) => this._msg(JSON.parse(e.data))
  }
  _msg(m) {
    if (m.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (m.type === "confirm_subscription") {
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeSyncStep1(enc, this.doc)
      this._send(enc)
      this._sub()
    } else if (m.message?.update) {
      const d = decoding.createDecoder(fromBase64(m.message.update))
      while (decoding.hasContent(d)) {
        if (decoding.readVarUint(d) === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          const t = syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
          if (encoding.length(enc) > 1) this._send(enc)
          if (t === syncProtocol.messageYjsSyncStep2) this._syn()
        } else {
          decoding.readVarUint8Array(d)
        }
      }
    }
  }
  _send(enc) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({
      command: "message",
      identifier: this.identifier,
      data: JSON.stringify({ update: toBase64(encoding.toUint8Array(enc)) }),
    }))
  }
  edit(text) {
    const frag = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const p = new Y.XmlElement("paragraph")
      p.insert(0, [new Y.XmlText(text)])
      frag.insert(frag.length, [p])
    })
  }
  text() {
    return this.doc.getXmlFragment("default").toString()
  }
}

const auditCount = async () => (await (await fetch(`http://127.0.0.1:${PORT}/docs/${ROOM}/audit`)).json()).count

if (PHASE === "write") {
  const c = new Client(ROOM)
  await c.subscribed
  await sleep(100)
  for (let i = 1; i <= EDITS; i++) {
    c.edit(`edit-${i}`)
    await sleep(10)
  }
  // Wait until every edit is durably recorded before we allow the kill.
  for (let tries = 0; tries < 100; tries++) {
    if ((await auditCount()) >= EDITS) break
    await sleep(50)
  }
  const count = await auditCount()
  if (count < EDITS) {
    console.log(`FAIL: only ${count}/${EDITS} edits recorded before kill`)
    process.exit(1)
  }
  console.log(`wrote ${EDITS} edits, ${count} recorded (fsync'd); safe to kill`)
  process.exit(0)
}

// PHASE === "verify": fresh client after the restart. The server's registry is
// empty; on_load must rebuild the document from the audit log.
const c = new Client(ROOM)
await c.subscribed
await c.synced
await sleep(300)

let missing = 0
for (let i = 1; i <= EDITS; i++) {
  if (!c.text().includes(`edit-${i}`)) {
    console.log(`FAIL: edit-${i} was lost across the crash`)
    missing++
  }
}

const liveText = await serverText(`http://127.0.0.1:${PORT}`, ROOM)
const liveMissing = []
for (let i = 1; i <= EDITS; i++) if (!liveText.includes(`edit-${i}`)) liveMissing.push(i)

if (missing === 0 && liveMissing.length === 0) {
  console.log(`PASS: all ${EDITS} edits recovered from the audit log after kill -9`)
  process.exit(0)
}
console.log(`FAIL: ${missing} missing for client, ${liveMissing.length} missing on server`)
process.exit(1)
