// Raw-WebSocket security check for the demo's whisper opt-out.
//
//   PORT=3888 node raw_ws_whisper_check.mjs
//
// Speaks the AnyCable/Action Cable wire protocol directly (no yrby-client), so
// it can do what a hostile client would: whisper a document frame to a room's
// peers, bypassing Ruby. On this demo the channels strip the whisper option, so
// anycable-go never whisper-enables the stream and drops the whisper. This
// asserts that:
//
//   1. a whispered { update: <document frame> } does NOT reach a second client
//      in the room, and creates no document in the store (the injection is dead);
//   2. the SAME frame sent normally IS relayed to the peer and IS persisted (the
//      transport works — it is specifically whisper that is dropped);
//   3. an awareness frame sent normally IS relayed to the peer (presence works
//      over the guarded send path, at the raw protocol level).
//
// Uses Node's built-in global WebSocket (Node 22+). No browser needed.
import { execFile } from "node:child_process"
import { promisify } from "node:util"

const pexec = promisify(execFile)
const PORT = process.env.PORT || 3888
const BASE = `http://127.0.0.1:${PORT}`
const ORIGIN = BASE
const ROOM_ID = `rawws-${Date.now().toString(36)}`
const ROOM = `tiptap/${ROOM_ID}`

// DocumentChannel subscribes by signed grant, not by key: fetch the demo page
// the way a browser would and lift the token it rendered. Even this hostile
// client has to go through the front door to name a document.
const page = await fetch(`${BASE}/demos/tiptap/${ROOM_ID}`).then((r) => r.text())
const TOKEN = page.match(/data-token="([^"]+)"/)?.[1]
if (!TOKEN) { console.log("FAIL: could not lift a room token from the demo page"); process.exit(1) }
const IDENTIFIER = JSON.stringify({ channel: "DocumentChannel", token: TOKEN })

// A real HELLO document sync frame (messageSync/Update), and a real awareness
// frame (messageAwareness) — the exact base64 payloads a browser puts on the wire.
const DOC_FRAME = "AAIbAQEBAAQBB2NvbnRlbnQLaGVsbG8gd29ybGQA"
const AWARENESS_FRAME = "AS0BKgEpeyJjdXJzb3IiOnsieCI6MTAsInkiOjIwfSwidXNlciI6ImFsaWNlIn0="

let failures = 0
const check = (label, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${label}`); if (!ok) failures++ }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// One raw cable client: connects, records every incoming message, and can send
// commands. AnyCable/Action Cable frames are JSON over a text WebSocket.
function client(name) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/cable`, [], { headers: { Origin: ORIGIN } })
  const received = []
  let welcomed
  const welcome = new Promise((r) => { welcomed = r })
  ws.addEventListener("message", (e) => {
    const msg = JSON.parse(e.data)
    if (msg.type === "welcome") welcomed()
    if (msg.type === "ping") return
    received.push(msg)
  })
  const open = new Promise((r, j) => {
    ws.addEventListener("open", r)
    ws.addEventListener("error", j)
  })
  return {
    name,
    received,
    async ready() { await open; await welcome },
    send(obj) { ws.send(JSON.stringify(obj)) },
    subscribe() { this.send({ command: "subscribe", identifier: IDENTIFIER }) },
    message(payload) { this.send({ command: "message", identifier: IDENTIFIER, data: JSON.stringify(payload) }) },
    whisper(data) { this.send({ command: "whisper", identifier: IDENTIFIER, data }) },
    close() { ws.close() },
    // Any inbound frame whose data carries this exact base64 update.
    got(update) {
      return this.received.some((m) => m.message && m.message.update === update)
    },
    confirmed() {
      return this.received.some((m) => m.type === "confirm_subscription" && m.identifier === IDENTIFIER)
    },
  }
}

async function storedUpdateCount() {
  const { stdout } = await pexec(
    "bin/rails",
    ["runner", `print Y::Document.where(key: ${JSON.stringify(ROOM)}).sum { |d| d.updates.count }`],
    { cwd: new URL("..", import.meta.url).pathname, env: { ...process.env, OBJC_DISABLE_INITIALIZE_FORK_SAFETY: "YES" } },
  )
  const n = stdout.trim().split("\n").pop()
  return Number(n)
}

const A = client("A")
const B = client("B")
await Promise.all([A.ready(), B.ready()])
A.subscribe()
B.subscribe()
await sleep(800)
check("both raw clients subscribed", A.confirmed() && B.confirmed())

// --- 1) A whispered document frame must NOT reach B, and must persist nothing ---
const before = await storedUpdateCount()
A.whisper({ update: DOC_FRAME })
await sleep(1200)
check("a whispered document frame does not reach the peer", !B.got(DOC_FRAME))
const afterWhisper = await storedUpdateCount()
check(`the store is unchanged by the whisper (updates ${before} -> ${afterWhisper})`, afterWhisper === before)

// --- 2) The same frame sent normally IS relayed and IS persisted -----------------
A.message({ update: DOC_FRAME, id: 1 })
await sleep(1200)
check("the same frame sent via send reaches the peer", B.got(DOC_FRAME))
check("...and A gets an ack", A.received.some((m) => m.message && m.message.ack === 1))
const afterSend = await storedUpdateCount()
check(`...and it is persisted (updates ${afterWhisper} -> ${afterSend})`, afterSend === afterWhisper + 1)

// --- 3) Awareness sent normally IS relayed (presence over the guarded path) ------
A.message({ update: AWARENESS_FRAME })
await sleep(1000)
check("an awareness frame sent via send reaches the peer", B.got(AWARENESS_FRAME))

A.close()
B.close()
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: whisper is dropped on the demo; send is relayed and persisted; awareness rides send")
