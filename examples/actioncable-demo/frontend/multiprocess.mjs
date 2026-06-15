// Multi-process test. Two independent Rails server processes (different ports)
// share documents through a Redis cable adapter and a shared audit store.
// Clients are split across the two processes, which mirrors a real Rails
// deployment (multiple Puma workers or dynos) rather than a single process.
//
//   Boot two servers sharing Redis and the audit dir, then:
//   PORTS=3777,3778 bun multiprocess.mjs
//
// Checks cross-process liveness, that both processes' server-side replicas stay
// current (server reads and late-joiner handshakes), cross-process presence,
// and a single shared audit log with every change recorded exactly once.
import * as Y from "yjs"
import * as awarenessProtocol from "y-protocols/awareness"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText as serverTextRead } from "./server_read.mjs"

const PORTS = (process.env.PORTS || "3777,3778").split(",").map(Number)
const ROOM = `mp-${process.pid}`
const EDITS = Number(process.env.EDITS || 10)
const MSG_SYNC = 0
const MSG_AWARENESS = 1

const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}

class Client {
  constructor(port, room = ROOM) {
    this.port = port
    this.doc = new Y.Doc()
    this.awareness = new awarenessProtocol.Awareness(this.doc)
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.synced = new Promise((r) => (this._syn = r))
    this.doc.on("update", (u, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, u)
      this._send(enc)
    })
    this.ws = new WebSocket(`ws://localhost:${port}/cable`, ["actioncable-v1-json"])
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
      const d = decoding.createDecoder(fromB64(m.message.m))
      while (decoding.hasContent(d)) {
        const type = decoding.readVarUint(d)
        if (type === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          const t = syncProtocol.readSyncMessage(d, enc, this.doc, "remote")
          if (encoding.length(enc) > 1) this._send(enc)
          if (t === syncProtocol.messageYjsSyncStep2) this._syn()
        } else if (type === MSG_AWARENESS) {
          awarenessProtocol.applyAwarenessUpdate(this.awareness, decoding.readVarUint8Array(d), "remote")
        }
      }
    }
  }
  _send(enc) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({
      command: "message",
      identifier: this.identifier,
      data: JSON.stringify({ m: toB64(encoding.toUint8Array(enc)) }),
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
  setPresence(state) {
    this.awareness.setLocalState(state)
    const enc = encoding.createEncoder()
    encoding.writeVarUint(enc, MSG_AWARENESS)
    encoding.writeVarUint8Array(enc, awarenessProtocol.encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
    this._send(enc)
  }
  presenceNames() {
    return [...this.awareness.getStates().values()].map((s) => s.user?.name).filter(Boolean)
  }
  text() { return this.doc.getXmlFragment("default").toString() }
  state() { return Y.encodeStateAsUpdate(this.doc) }
}

const serverText = (port, room = ROOM) => serverTextRead(`http://localhost:${port}`, room)
const auditCount = async (port) =>
  (await (await fetch(`http://localhost:${port}/docs/${ROOM}/audit`)).json()).count

// --- Scenario ---------------------------------------------------------------

const [portA, portB] = PORTS
console.log(`two processes: ${portA} and ${portB}, room ${ROOM}`)

const a1 = new Client(portA)
const a2 = new Client(portA)
const b1 = new Client(portB)
const b2 = new Client(portB)
const clients = [a1, a2, b1, b2]
await Promise.all(clients.map((c) => c.subscribed))
await sleep(200)

// Edits interleaved across both processes.
for (let i = 1; i <= EDITS; i++) {
  a1.edit(`A1-${i}`)
  b1.edit(`B1-${i}`)
  a2.edit(`A2-${i}`)
  b2.edit(`B2-${i}`)
  await sleep(20)
}
await sleep(1200) // allow cross-process propagation + audit writes

// 1. All clients converge byte-for-byte, regardless of which process they're on.
const ref = a1.state()
check("all clients across both processes converged byte-for-byte",
  clients.every((c) => {
    const s = c.state()
    return s.length === ref.length && s.every((x, i) => x === ref[i])
  }))

// 2. Both processes' server-side replicas are current, not just the clients.
const textA = await serverText(portA)
const textB = await serverText(portB)
let bothFresh = true
for (let i = 1; i <= EDITS; i++) {
  for (const tag of ["A1", "A2", "B1", "B2"]) {
    if (!textA.includes(`${tag}-${i}`) || !textB.includes(`${tag}-${i}`)) bothFresh = false
  }
}
check("both processes' server-side replicas reflect every edit", bothFresh)

// 3. A late client on process B gets the full document via B's handshake.
const late = new Client(portB)
await late.subscribed
await late.synced
await sleep(300)
let lateOk = true
for (let i = 1; i <= EDITS; i++) {
  if (!late.text().includes(`A1-${i}`) || !late.text().includes(`B2-${i}`)) lateOk = false
}
check("a late joiner on the OTHER process receives the whole document", lateOk)

// 4. Cross-process presence: a1 (A) sets presence, b1 (B) must see it.
a1.setPresence({ user: { name: "ALICE-A" } })
b2.setPresence({ user: { name: "BOB-B" } })
await sleep(600)
check("presence crosses processes (B sees A's cursor)", b1.presenceNames().includes("ALICE-A"))
check("presence crosses processes (A sees B's cursor)", a2.presenceNames().includes("BOB-B"))

// 5. One shared audit log: every change recorded exactly once (not per process).
const countA = await auditCount(portA)
const countB = await auditCount(portB)
check(`shared audit log has every change once (${countA} == ${EDITS * 4})`, countA === EDITS * 4)
check("both processes see the same shared audit log", countA === countB)

clients.forEach((c) => c.ws.close())
late.ws.close()
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: documents are shared correctly across two server processes")
process.exit(0)
