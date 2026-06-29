// Probe yrby's behavior under AnyCable. WS is terminated by anycable-go
// (WS_PORT), channel logic runs in the AnyCable RPC server (a different Ruby
// process than Puma), and HTTP (/content) is served by Puma (HTTP_PORT).
//
// We check the things likely to break under AnyCable:
//   - does subscribing even work (stream_from has a custom block)?
//   - liveness: does B receive A's edit?
//   - echo: does A receive its own edit back? (store-backed streams echo to the
//     sender; applying the same CRDT update twice is a no-op)
//   - server-side read: does Puma's /content reflect the doc, given it holds no
//     replica and the RPC process handled the edit?
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverDoc } from "./server_read.mjs"

const WS_PORT = process.env.WS_PORT || 8080
const HTTP_PORT = process.env.HTTP_PORT || 3777
const ROOM = `acprobe-${process.pid}`
const MSG_SYNC = 0
const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

class Client {
  constructor(name) {
    this.name = name
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: ROOM })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.confirmed = false
    this.echoed = 0 // times we received a frame carrying our own update
    this.localUpdates = []
    this.doc.on("update", (u, origin) => {
      if (origin === "remote") return
      this.localUpdates.push(toB64(u))
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
      this.confirmed = true
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeSyncStep1(enc, this.doc)
      this._send(enc)
      this._sub()
    } else if (m.type === "reject_subscription") {
      console.log(`  [${this.name}] subscription REJECTED`)
      this._sub()
    } else if (m.message?.update) {
      const raw = m.message.update
      // did this frame carry one of our own local updates?
      const d = decoding.createDecoder(fromB64(raw))
      while (decoding.hasContent(d)) {
        const t = decoding.readVarUint(d)
        if (t === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
        } else {
          try { decoding.readVarUint8Array(d) } catch { break }
        }
      }
      if (this.localUpdates.some((u) => raw.includes(u.slice(0, 12)))) this.echoed++
    }
  }
  _send(enc) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({
      command: "message", identifier: this.identifier,
      data: JSON.stringify({ update: toB64(encoding.toUint8Array(enc)) }),
    }))
  }
  edit(text) {
    const frag = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const p = new Y.XmlElement("paragraph"); p.insert(0, [new Y.XmlText(text)])
      frag.insert(frag.length, [p])
    })
  }
  text() { return this.doc.getXmlFragment("default").toString() }
}

const a = new Client("A")
const b = new Client("B")
await Promise.all([a.subscribed, b.subscribed])
await sleep(300)
console.log(`subscribed: A=${a.confirmed} B=${b.confirmed}`)

a.edit("hello-from-A")
await sleep(1200)

console.log(`\nLIVENESS  B received A's edit:        ${b.text().includes("hello-from-A")}`)
console.log(`ECHO      A got its own edit back:     ${a.echoed > 0} (count ${a.echoed})`)

const { status, doc } = await serverDoc(`http://localhost:${HTTP_PORT}`, ROOM)
const serverView = doc ? doc.getXmlFragment("default").toString() : `status ${status}`
console.log(`SERVER    Puma /content (different process than RPC): ${status} ${serverView.slice(0, 120)}`)

a.ws.close(); b.ws.close()
process.exit(0)
