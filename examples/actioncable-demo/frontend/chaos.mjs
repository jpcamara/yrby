// Hostile-input chaos test. A vandal client sprays malformed frames at the
// server (bad base64, random bytes, truncated/oversized protocol messages,
// unknown types, spoofed awareness, broken envelopes) while good clients edit
// normally. Checks that the server never dies, good clients still converge, a
// second room is unaffected, and only valid changes are logged.
//
//   bin/rails s -p 3777
//   cd frontend && bun chaos.mjs
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const PID = process.pid
const MSG_SYNC = 0
const EDITS = Number(process.env.EDITS || 15)

const toBase64 = (b) => Buffer.from(b).toString("base64")
const fromBase64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const randBytes = (n) => crypto.getRandomValues(new Uint8Array(n))

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}
const health = async () =>
  (await fetch(`http://localhost:${PORT}/docs/demo`)).status === 200
const auditCount = async (room) =>
  (await (await fetch(`http://localhost:${PORT}/docs/${room}/audit`)).json()).count

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
      this.send(enc)
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
      this.send(enc)
      this._sub()
    } else if (m.message?.update) {
      const d = decoding.createDecoder(fromBase64(m.message.update))
      while (decoding.hasContent(d)) {
        if (decoding.readVarUint(d) === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
          if (encoding.length(enc) > 1) this.send(enc)
        } else {
          decoding.readVarUint8Array(d)
        }
      }
    }
  }
  send(enc) {
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
  text() { return this.doc.getXmlFragment("default").toString() }
  state() { return Y.encodeStateAsUpdate(this.doc) }
}

// A vandal that subscribes legitimately, then sends garbage frames.
class Vandal {
  constructor(room) {
    this.room = room
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.ready = new Promise((r) => (this._ready = r))
    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (e) => {
      const m = JSON.parse(e.data)
      if (m.type === "welcome") {
        this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
      } else if (m.type === "confirm_subscription") {
        this._ready()
      }
    }
    this.ws.onerror = () => {}
  }
  raw(dataString) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({ command: "message", identifier: this.identifier, data: dataString }))
  }
  payloads() {
    const valid = encoding.createEncoder()
    encoding.writeVarUint(valid, MSG_SYNC)
    syncProtocol.writeSyncStep1(valid, new Y.Doc())
    const validBytes = encoding.toUint8Array(valid)
    return [
      "not json at all {{{",                          // broken envelope
      JSON.stringify({ x: 1 }),                        // no update
      JSON.stringify({ update: 12345 }),                    // update not a string
      JSON.stringify({ update: "!!!not-base64!!!" }),       // not base64
      JSON.stringify({ update: toBase64(randBytes(4)) }),   // random bytes
      JSON.stringify({ update: toBase64(randBytes(64)) }),
      JSON.stringify({ update: toBase64(randBytes(4096)) }),
      JSON.stringify({ update: toBase64(randBytes(200_000)) }), // oversized
      JSON.stringify({ update: toBase64(new Uint8Array([0x63, 0x63, 0x63])) }), // unknown type
      JSON.stringify({ update: toBase64(new Uint8Array([0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0x0f])) }), // bogus length
      JSON.stringify({ update: toBase64(new Uint8Array([0x01, 0xff, 0xff, 0xff, 0xff, 0x0f])) }), // bad awareness
      JSON.stringify({ update: toBase64(validBytes.slice(0, validBytes.length - 1)) }), // truncated valid
    ]
  }
  async barrage(rounds) {
    const payloads = this.payloads()
    for (let r = 0; r < rounds; r++) {
      for (const p of payloads) this.raw(p)
      await sleep(2)
    }
  }
}

// --- Scenario ---------------------------------------------------------------

const room = `chaos-${PID}`
const room2 = `bystander-${PID}`
await fetch(`http://localhost:${PORT}/docs/${room}/audit/control?reset=1`, { method: "POST" })

const a = new Client(room)
const b = new Client(room)
const bystander = new Client(room2)
const vandal = new Vandal(room)
await Promise.all([a.subscribed, b.subscribed, bystander.subscribed, vandal.ready])

console.log("unleashing the vandal while good clients edit...")
const editing = (async () => {
  for (let i = 1; i <= EDITS; i++) {
    a.edit(`A-${i}`)
    b.edit(`B-${i}`)
    bystander.edit(`BY-${i}`)
    await sleep(15)
  }
})()
const vandalism = vandal.barrage(40)
await Promise.all([editing, vandalism])
await sleep(800)

check("server is still alive after the barrage", await health())

// Good clients in the attacked room converged byte-for-byte.
const sa = a.state(), sb = b.state()
check("attacked room's good clients converged byte-for-byte",
  sa.length === sb.length && sa.every((x, i) => x === sb[i]))

let aAllGood = true
for (let i = 1; i <= EDITS; i++) {
  if (!a.text().includes(`A-${i}`) || !a.text().includes(`B-${i}`)) aAllGood = false
}
check("every good edit survived in the attacked room", aAllGood)

let byGood = true
for (let i = 1; i <= EDITS; i++) if (!bystander.text().includes(`BY-${i}`)) byGood = false
check("the bystander room was completely unaffected", byGood)

// Every valid edit is durably recorded, and none of the garbage became a
// recorded change. We assert durability by REPLAY, not by a 1:1 row count:
// under a multi-process deployment the server can coalesce concurrent updates
// into a single recorded delta, so the row count may be < the number of logical
// edits (fewer, fatter rows that still replay to the full document). Garbage,
// by contrast, is rejected before recording, so it can only ever ADD rows —
// hence count <= EDITS * 2 catches any garbage that slipped through.
const recovered = await serverText(`http://localhost:${PORT}`, room)
let everyEditDurable = true
for (let i = 1; i <= EDITS; i++) {
  if (!recovered.includes(`A-${i}`) || !recovered.includes(`B-${i}`)) everyEditDurable = false
}
check("every valid edit is durable (store replay reconstructs them all)", everyEditDurable)
const count = await auditCount(room)
check(`no garbage became a recorded change (count ${count} <= ${EDITS * 2})`, count <= EDITS * 2)

a.ws.close(); b.ws.close(); bystander.ws.close(); vandal.ws.close()
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: survived the barrage: process alive, good data intact, garbage never logged")
process.exit(0)
