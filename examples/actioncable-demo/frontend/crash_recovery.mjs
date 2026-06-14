// Crash-recovery durability test. Run in two phases around a hard `kill -9`
// of the server (orchestrated by crash_recovery.sh):
//
//   PHASE=write  ROOM=... bun crash_recovery.mjs   # make edits, wait until logged
//   <SIGKILL the server, restart it>
//   PHASE=verify ROOM=... bun crash_recovery.mjs   # assert nothing was lost
//
// Because audit mode records every change (fsync) BEFORE it's applied or
// broadcast, every acknowledged edit is on disk when the server dies. On
// restart, on_load replays the log and the document is whole — no loss
// window, unlike a debounced-persistence server.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

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
    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
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
    } else if (m.message?.m) {
      const d = decoding.createDecoder(fromBase64(m.message.m))
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
      data: JSON.stringify({ m: toBase64(encoding.toUint8Array(enc)) }),
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

const auditCount = async () => (await (await fetch(`http://localhost:${PORT}/docs/${ROOM}/audit`)).json()).count

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
  console.log(`wrote ${EDITS} edits, ${count} recorded (fsync'd) — safe to kill`)
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

const live = await (await fetch(`http://localhost:${PORT}/docs/${ROOM}/content`)).json()
const liveText = (live.content || []).flatMap((n) => (n.content || []).map((t) => t.text)).join("\n")
const liveMissing = []
for (let i = 1; i <= EDITS; i++) if (!liveText.includes(`edit-${i}`)) liveMissing.push(i)

if (missing === 0 && liveMissing.length === 0) {
  console.log(`PASS — all ${EDITS} edits recovered from the audit log after kill -9`)
  process.exit(0)
}
console.log(`FAIL: ${missing} missing for client, ${liveMissing.length} missing on server`)
process.exit(1)
