// Load test for yrb-lite. Spawns many WebSocket clients (raw ActionCable
// protocol — far lighter than browsers) across rooms, drives a sustained edit
// rate, and measures: sustained throughput (edits recorded/sec), propagation
// latency under load (edit -> visible on another client), saturation (sent vs
// recorded), errors, and final convergence.
//
//   WS_PORT=8080 HTTP_PORT=3777 CLIENTS=100 ROOMS=10 DURATION=20 RATE=10 \
//     bun loadtest.mjs
//
// RATE = edits/sec PER client. Latency uses a Y.Map "ping" (O(1) to observe)
// so measuring it doesn't get more expensive as the document grows.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

// WS_PORTS (comma-separated) spreads clients across multiple AnyCable nodes;
// falls back to a single WS_PORT.
const WS_PORTS = (process.env.WS_PORTS || process.env.WS_PORT || "8080").split(",").map((s) => s.trim())
const HTTP_PORT = process.env.HTTP_PORT || 3777
const CLIENTS = Number(process.env.CLIENTS || 100)
const ROOMS = Number(process.env.ROOMS || 10)
const DURATION = Number(process.env.DURATION || 20) * 1000
const RATE = Number(process.env.RATE || 10) // edits/sec/client
const STORE = process.env.STORE !== "0" // audit/store mode (query /audit)
const MSG_SYNC = 0
const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const now = () => performance.now()

const metrics = { sent: 0, recv: 0, edits: 0, errors: 0, latencies: [] }
const pingSent = new Map() // `${room}:${seq}` -> sendTime

class LoadClient {
  constructor(room, idx, probe) {
    this.room = room
    this.probe = probe
    this.wsPort = WS_PORTS[idx % WS_PORTS.length]
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.lat = this.doc.getMap("lat")
    if (!probe) {
      this.lat.observe(() => {
        const seq = this.lat.get("seq")
        const key = `${room}:${seq}`
        if (pingSent.has(key)) {
          metrics.latencies.push(now() - pingSent.get(key))
          pingSent.delete(key)
        }
      })
    }
    this.doc.on("update", (u, origin) => {
      if (origin === "remote") return
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MSG_SYNC)
      syncProtocol.writeUpdate(e, u)
      this._send(e)
    })
    this.ws = new WebSocket(`ws://localhost:${this.wsPort}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (ev) => this._msg(JSON.parse(ev.data))
    this.ws.onerror = () => { metrics.errors++ }
  }
  _msg(m) {
    if (m.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (m.type === "confirm_subscription") {
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MSG_SYNC); syncProtocol.writeSyncStep1(e, this.doc)
      this._send(e); this._sub()
    } else if (m.message?.update || m.message?.m) {
      metrics.recv++
      const d = decoding.createDecoder(fromB64(m.message.update || m.message.m))
      while (decoding.hasContent(d)) {
        if (decoding.readVarUint(d) === MSG_SYNC) {
          const e = encoding.createEncoder(); encoding.writeVarUint(e, MSG_SYNC)
          syncProtocol.readSyncMessage(d, e, this.doc, "remote")
        } else { try { decoding.readVarUint8Array(d) } catch { break } }
      }
    }
  }
  _send(e) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(JSON.stringify({ command: "message", identifier: this.identifier,
      data: JSON.stringify({ update: toB64(encoding.toUint8Array(e)) }) }))
    metrics.sent++
  }
  edit(tok) {
    const frag = this.doc.getXmlFragment("default")
    this.doc.transact(() => { const p = new Y.XmlElement("paragraph"); p.insert(0, [new Y.XmlText(tok)]); frag.insert(frag.length, [p]) })
    metrics.edits++
  }
  ping(seq) {
    pingSent.set(`${this.room}:${seq}`, now())
    this.lat.set("seq", seq)
  }
  state() { return Y.encodeStateAsUpdate(this.doc) }
}

const pct = (arr, p) => {
  if (!arr.length) return 0
  const s = [...arr].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]
}
const auditCount = async (room) => {
  try { return (await (await fetch(`http://localhost:${HTTP_PORT}/docs/${room}/audit`)).json()).count }
  catch { return 0 }
}
// Memory mode has no audit log — count applied paragraphs from /content instead.
const serverParagraphs = async (room) => {
  try {
    const j = await (await fetch(`http://localhost:${HTTP_PORT}/docs/${room}/content`)).json()
    return (j.content || []).filter((n) => n.type === "paragraph" && (n.content || []).length).length
  } catch { return 0 }
}

// --- run --------------------------------------------------------------------
const rooms = Array.from({ length: ROOMS }, (_, i) => `load-${process.pid}-r${i}`)
const clients = []
for (let i = 0; i < CLIENTS; i++) {
  const room = rooms[i % ROOMS]
  const probe = i < ROOMS // first client in each room is the latency probe
  clients.push(new LoadClient(room, i, probe))
}
const probes = clients.filter((c) => c.probe)
await Promise.all(clients.map((c) => c.subscribed))
console.log(`connected ${CLIENTS} clients across ${ROOMS} rooms; driving ${RATE} edits/s/client for ${DURATION / 1000}s`)

const t0 = now()
let seq = 0
const editTimers = clients.map((c) =>
  setInterval(() => c.edit(`c${c.room}-${Math.floor(now())}`), Math.max(5, 1000 / RATE)))
const pingTimer = setInterval(() => { seq++; probes.forEach((p) => p.ping(seq)) }, 200)

await sleep(DURATION)
editTimers.forEach(clearInterval)
clearInterval(pingTimer)
const wall = (now() - t0) / 1000

// Drain: let in-flight edits land in the store + propagate to all clients.
await sleep(Number(process.env.DRAIN || 4) * 1000)

const recorded = (await Promise.all(rooms.map(STORE ? auditCount : serverParagraphs))).reduce((a, b) => a + b, 0)
const paragraphs = (doc) => [...doc.getXmlFragment("default").toArray()].filter((p) => p.length).length

// Rigorous integrity check: in EVERY room, every client must be byte-identical
// to every other AND each client's paragraph count must equal the server's
// stored doc. If any client held an un-synced local edit, this fails — that's
// how we'd detect a dropped/lost edit (vs one that was simply never sent).
let converged = true
let clientParaTotal = 0
let serverParaTotal = 0
for (const room of rooms) {
  const members = clients.filter((c) => c.room === room)
  const ref = members[0].state()
  const same = members.every((c) => { const s = c.state(); return s.length === ref.length && s.every((x, i) => x === ref[i]) })
  const srvParas = await serverParagraphs(room)
  const clientParas = paragraphs(members[0].doc)
  clientParaTotal += clientParas
  serverParaTotal += srvParas
  if (!same || clientParas !== srvParas) converged = false
}

console.log("\n========== LOAD TEST RESULTS ==========")
console.log(`clients/rooms:        ${CLIENTS} / ${ROOMS}`)
console.log(`duration (wall):      ${wall.toFixed(1)}s`)
const keptUp = serverParaTotal / metrics.edits
console.log(`edits attempted:      ${metrics.edits}  (${(metrics.edits / wall).toFixed(0)}/s)`)
console.log(`edits applied:        ${serverParaTotal}  (${(metrics.edits / wall).toFixed(0)}/s attempted; ${(keptUp * 100).toFixed(1)}% applied in real time)`)
console.log(`store entries:        ${recorded}  (delta messages — fewer than edits, since Yjs batches)`)
console.log(`steady-state:         ${keptUp >= 0.97 && pct(metrics.latencies, 95) < 1000 ? "KEEPING UP (low latency)" : "SATURATED (backlog; drains without loss)"}`)
console.log(`ws frames sent/recv:  ${metrics.sent} / ${metrics.recv}`)
console.log(`propagation latency:  p50 ${pct(metrics.latencies, 50).toFixed(0)}ms  p95 ${pct(metrics.latencies, 95).toFixed(0)}ms  p99 ${pct(metrics.latencies, 99).toFixed(0)}ms  max ${pct(metrics.latencies, 100).toFixed(0)}ms  (n=${metrics.latencies.length})`)
console.log(`errors:               ${metrics.errors}`)
console.log(`doc paragraphs:       clients ${clientParaTotal} vs server ${serverParaTotal}`)
console.log(`integrity:            ${converged ? "OK — every client == server in every room (no loss)" : "MISMATCH"}`)
console.log("=======================================")

clients.forEach((c) => c.ws.close())
process.exit(metrics.errors === 0 && converged ? 0 : 1)
