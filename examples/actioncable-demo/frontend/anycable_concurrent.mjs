// Concurrent multi-client storm under AnyCable (store-backed server). N raw-WS
// clients connect to anycable-go (WS_PORT), edit concurrently, then we check
// that they all converge and that the shared store reflects every edit. The
// store is read via Puma's /content on HTTP_PORT, which is a different process.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const WS_PORT = process.env.WS_PORT || 8080
const HTTP_PORT = process.env.HTTP_PORT || 3777
const CLIENTS = Number(process.env.CLIENTS || 6)
const PARAS = Number(process.env.PARAS || 5)
const ROOM = `acstorm-${process.pid}`
const MSG_SYNC = 0
const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let failures = 0
const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }

class Client {
  constructor(i) {
    this.i = i
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: ROOM })
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
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeSyncStep1(enc, this.doc)
      this._send(enc)
      this._sub()
    } else if (m.message?.update || m.message?.m) {
      const d = decoding.createDecoder(fromB64(m.message.update || m.message.m))
      while (decoding.hasContent(d)) {
        if (decoding.readVarUint(d) === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
        } else { try { decoding.readVarUint8Array(d) } catch { break } }
      }
    }
  }
  _send(enc) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({
      command: "message", identifier: this.identifier,
      data: JSON.stringify({ update: toB64(encoding.toUint8Array(enc)) }),
    }))
  }
  addParagraph(text) {
    const frag = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const p = new Y.XmlElement("paragraph"); p.insert(0, [new Y.XmlText(text)])
      frag.insert(frag.length, [p])
    })
  }
  state() { return Y.encodeStateAsUpdate(this.doc) }
  text() { return this.doc.getXmlFragment("default").toString() }
}

const clients = Array.from({ length: CLIENTS }, (_, i) => new Client(i))
await Promise.all(clients.map((c) => c.subscribed))
await sleep(300)

// Every client appends its own tagged paragraphs, all at the same time.
const tokens = []
await Promise.all(clients.map(async (c) => {
  for (let j = 0; j < PARAS; j++) {
    const tok = `c${c.i}p${j}`
    tokens.push(tok)
    c.addParagraph(tok)
    await sleep(15)
  }
}))
await sleep(2000) // converge + store writes

const ref = clients[0].state()
check("all clients converged byte-for-byte", clients.every((c) => {
  const s = c.state()
  return s.length === ref.length && s.every((x, i) => x === ref[i])
}))
const t0 = clients[0].text()
check(`every token present across clients (${tokens.length})`, tokens.every((t) => t0.includes(t)))

// The store (Puma /content, a separate process from the RPC server) agrees.
const srv = await serverText(`http://localhost:${HTTP_PORT}`, ROOM)
check("Puma /content reflects every edit (cross-process via store)", tokens.every((t) => srv.includes(t)))

clients.forEach((c) => c.ws.close())
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: ${CLIENTS} concurrent clients under AnyCable: converged, store has all ${tokens.length} edits`)
process.exit(0)
