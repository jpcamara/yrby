// Load test for the yrby site. Raw ActionCable WebSocket clients (far lighter
// than browsers) against DocumentChannel, spread across rooms, driving a
// sustained edit rate. Measures connections held, throughput (edits acked/sec
// — the channel acks every recorded update), fan-out (remote updates seen),
// propagation latency (edit -> visible on a peer), saturation (sent vs acked),
// and errors.
//
//   BASE=http://192.168.1.161:4321 CLIENTS=200 ROOMS=20 DURATION=30 RATE=2 \
//     node loadtest_site.mjs
//
// RATE = edits/sec PER client. Keys use a real demo slug so the channel's
// key validation accepts them. Latency uses a Y.Map "ping" (O(1) to observe).
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

const BASE = process.env.BASE || "http://127.0.0.1:4321"
const WS = BASE.replace(/^http/, "ws") + "/cable"
const CLIENTS = Number(process.env.CLIENTS || 200)
const ROOMS = Number(process.env.ROOMS || 20)
const DURATION = Number(process.env.DURATION || 30) * 1000
const RATE = Number(process.env.RATE || 2)
const SLUG = process.env.SLUG || "spreadsheet"
const MSG_SYNC = 0
const toB64 = (b) => Buffer.from(b).toString("base64")
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const now = () => performance.now()

const m = { opened: 0, subscribed: 0, sent: 0, acked: 0, recv: 0, edits: 0, errors: 0, rejected: 0, lat: [] }
const pingSent = new Map()

class Client {
  constructor(room, idx, pinger) {
    this.room = room
    this.pinger = pinger // the room's designated pinger sends pings; peers time them
    this.frameId = 0
    this.key = `${SLUG}/${room}`
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: this.key })
    this.subscribed = new Promise((r) => (this._sub = r))
    this.ping = this.doc.getMap("ping")
    if (!pinger) {
      this.ping.observe((_e, tx) => {
        if (tx.origin !== "remote") return // only a ping that arrived from a peer counts
        const k = `${room}:${this.ping.get("seq")}`
        if (pingSent.has(k)) { m.lat.push(now() - pingSent.get(k)); pingSent.delete(k) }
      })
    }
    this.doc.on("update", (u, origin) => {
      if (origin === "remote") return
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MSG_SYNC); syncProtocol.writeUpdate(e, u)
      this._send(e)
    })
    this.ws = new WebSocket(WS, ["actioncable-v1-json"])
    this.ws.onopen = () => { m.opened++ }
    this.ws.onmessage = (ev) => this._msg(JSON.parse(ev.data))
    this.ws.onerror = () => { m.errors++ }
  }
  _msg(msg) {
    if (msg.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (msg.type === "reject_subscription") {
      m.rejected++; this._sub()
    } else if (msg.type === "confirm_subscription") {
      m.subscribed++
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MSG_SYNC); syncProtocol.writeSyncStep1(e, this.doc)
      this._send(e); this._sub()
    } else if (msg.message?.ack !== undefined) {
      m.acked++
    } else if (msg.message?.update) {
      m.recv++
      const d = decoding.createDecoder(fromB64(msg.message.update))
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
    // yrby's reliable delivery acks frames that carry an id; document updates
    // get one so acked/s measures recorded throughput. Sync-protocol replies
    // (SyncStep1) go without an id — they are answered, not recorded.
    this.ws.send(JSON.stringify({ command: "message", identifier: this.identifier,
      data: JSON.stringify({ update: toB64(encoding.toUint8Array(e)), id: ++this.frameId }) }))
    m.sent++
  }
  edit(tok) {
    this.doc.transact(() => this.doc.getMap("cells").set(tok, (this.doc.getMap("cells").get(tok) || 0) + 1))
    m.edits++
  }
  sendPing(seq) { pingSent.set(`${this.room}:${seq}`, now()); this.ping.set("seq", seq) }
  close() { try { this.ws.close() } catch { /* already closing */ } }
}

const pct = (a, p) => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] }

async function main() {
  console.log(`load: ${CLIENTS} clients / ${ROOMS} rooms / ${RATE} edits/s/client / ${DURATION / 1000}s -> ${WS}`)
  const clients = []
  for (let i = 0; i < CLIENTS; i++) {
    // the first client in each room is its pinger; the rest time the pings
    clients.push(new Client(`lt-${i % ROOMS}`, i, i < ROOMS))
    if (i % 25 === 24) await sleep(60) // ramp, don't SYN-flood the accept queue
  }
  await Promise.race([Promise.all(clients.map((c) => c.subscribed)), sleep(20000)])
  console.log(`connected: ${m.opened} opened, ${m.subscribed} subscribed, ${m.rejected} rejected`)

  const t0 = now()
  const ticker = setInterval(() => {
    for (const c of clients) {
      if (c.ws.readyState !== WebSocket.OPEN) continue
      // RATE edits/s/client, fractional: whole part always, remainder by chance,
      // so RATE=0.1 means each client edits ~once per 10 seconds.
      let n = Math.floor(RATE)
      if (Math.random() < RATE - n) n++
      for (let k = 0; k < n; k++) c.edit(`c${Math.floor(Math.random() * 50)}`)
    }
    // one client per room pings for latency
    for (let r = 0; r < ROOMS; r++) clients[r]?.sendPing(Math.floor(now()))
  }, 1000)

  await sleep(DURATION)
  clearInterval(ticker)
  const secs = (now() - t0) / 1000
  await sleep(2000) // drain in-flight acks

  console.log("\n=== results ===")
  console.log(`sockets:     ${m.opened} opened, ${m.subscribed} subscribed, ${m.rejected} rejected, ${m.errors} errors`)
  console.log(`edits:       ${m.edits} attempted, ${m.sent} frames sent, ${m.acked} acked`)
  console.log(`throughput:  ${(m.acked / secs).toFixed(0)} acked/s, ${(m.recv / secs).toFixed(0)} remote-updates/s (fan-out)`)
  console.log(`saturation:  ${(100 * m.acked / Math.max(1, m.sent)).toFixed(1)}% of sent frames acked`)
  console.log(`latency ms:  p50 ${pct(m.lat, 50).toFixed(0)}  p90 ${pct(m.lat, 90).toFixed(0)}  p99 ${pct(m.lat, 99).toFixed(0)}  (n=${m.lat.length})`)
  clients.forEach((c) => c.close())
  await sleep(500)
  process.exit(0)
}
main()
