// Checks record-before-distribute under AnyCable: a change is only published to
// other clients once it has been stored. WS is terminated by anycable-go
// (WS_PORT), channel logic runs in the RPC server, and the store fault controls
// go through Puma (HTTP_PORT) and reach the RPC process via a shared file.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const WS_PORT = process.env.WS_PORT || 8080
const HTTP_PORT = process.env.HTTP_PORT || 3777
const BASE = `http://localhost:${HTTP_PORT}`
const MSG_SYNC = 0
const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let failures = 0
const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }

class Client {
  constructor(room) {
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.doc.on("update", (u, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, u)
      this._send(enc)
    })
    this.ws = new WebSocket(`ws://localhost:${WS_PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (e) => this._msg(JSON.parse(e.data))
    this.ws.onerror = () => {}
  }
  _msg(m) {
    if (m.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (m.type === "confirm_subscription") {
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC); syncProtocol.writeSyncStep1(enc, this.doc)
      this._send(enc); this._sub()
    } else if (m.message?.update || m.message?.m) {
      const d = decoding.createDecoder(fromB64(m.message.update || m.message.m))
      while (decoding.hasContent(d)) {
        if (decoding.readVarUint(d) === MSG_SYNC) {
          const enc = encoding.createEncoder(); encoding.writeVarUint(enc, MSG_SYNC)
          syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
        } else { try { decoding.readVarUint8Array(d) } catch { break } }
      }
    }
  }
  _send(enc) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({ command: "message", identifier: this.identifier,
      data: JSON.stringify({ update: toB64(encoding.toUint8Array(enc)) }) }))
  }
  edit(t) {
    const frag = this.doc.getXmlFragment("default")
    this.doc.transact(() => { const p = new Y.XmlElement("paragraph"); p.insert(0, [new Y.XmlText(t)]); frag.insert(frag.length, [p]) })
  }
  has(t) { return this.doc.getXmlFragment("default").toString().includes(t) }
}

const control = (room, params) =>
  fetch(`${BASE}/docs/${room}/audit/control?${new URLSearchParams(params)}`, { method: "POST" })
const auditCount = async (room) => (await (await fetch(`${BASE}/docs/${room}/audit`)).json()).count
const serverHas = async (room, tok) => (await serverText(BASE, room)).includes(tok)

// ===== Scenario 1: slow store, invisible until stored =======================
async function slowStore() {
  console.log("\n--- Slow store: nothing is published until it's stored ---")
  const room = `acg-slow-${process.pid}`
  await control(room, { reset: 1, delay_ms: 1500 })
  const a = new Client(room), b = new Client(room)
  await Promise.all([a.subscribed, b.subscribed]); await sleep(200)

  a.edit("SECRET")            // server's on_change (store write) blocks ~1.5s
  await sleep(500)            // mid-store window
  check("other client does NOT see it mid-store", !b.has("SECRET"))
  check("server /content does NOT show it mid-store", !(await serverHas(room, "SECRET")))
  check("audit store has nothing yet", (await auditCount(room)) === 0)
  const c = new Client(room)  // a fresh client whose handshake is served from the store
  await c.subscribed; await sleep(300)
  check("a fresh client's handshake does NOT include it", !c.has("SECRET"))

  await sleep(1500)           // store commits
  check("after it's stored, the other client sees it", b.has("SECRET"))
  check("after it's stored, /content shows it", await serverHas(room, "SECRET"))
  check("after it's stored, the audit store has exactly one entry", (await auditCount(room)) === 1)
  a.ws.close(); b.ws.close(); c.ws.close()
}

// ===== Scenario 2: store failure, nothing leaks ============================
async function storeFailure() {
  console.log("\n--- Store failure: a rejected change leaks to no one ---")
  const room = `acg-fail-${process.pid}`
  await control(room, { reset: 1, fail_once: 1 })
  const a = new Client(room), b = new Client(room)
  await Promise.all([a.subscribed, b.subscribed]); await sleep(200)

  a.edit("DOOMED")            // store write raises -> change rejected
  await sleep(800)
  check("other client never saw the rejected change", !b.has("DOOMED"))
  check("server /content does not contain it", !(await serverHas(room, "DOOMED")))
  check("audit store does not contain it", (await auditCount(room)) === 0)
  const c = new Client(room)
  await c.subscribed; await sleep(300)
  check("a fresh client's handshake does not include it", !c.has("DOOMED"))
  a.ws.close(); b.ws.close(); c.ws.close()
}

await slowStore()
await storeFailure()
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log("PASS: under AnyCable, a change reaches other clients only after it has been stored")
process.exit(0)
