// Authoritative audit scenarios — end to end, through real ActionCable, with
// multiple real clients and a fault-injectable store. Proves the one
// guarantee that matters: no one else sees a change until it has been stored.
//
//   1. Boot in audit mode:  AUDIT=1 RAILS_MAX_THREADS=8 CABLE_WORKERS=8 bin/rails s -p 3777
//   2. Run:                 cd frontend && bun audit_scenarios.mjs
//
// Scenarios:
//   1. Slow store      — while a change is being stored, NO other client sees
//                        it (not via live broadcast, not via the /content
//                        read, not via a fresh client's resync). After the
//                        store completes, everyone sees it and it's logged.
//   2. Store failure   — a failed store leaks nothing to anyone and is absent
//                        from the audit log.
//   3. Self-heal       — after a failed store, the client reconnects and
//                        re-offers the change; the (recovered) store records
//                        it and everyone converges.
//   4. Offline catch-up — edits made offline are recorded (as one merged diff)
//                        when the client reconnects, before others see them.
import * as Y from "yjs"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

const PORT = process.env.PORT || 3777
const BASE = `http://localhost:${PORT}`
const MSG_SYNC = 0

const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const fromBase64 = (b64) => new Uint8Array(Buffer.from(b64, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let failures = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}

class Client {
  constructor(room) {
    this.room = room
    this.doc = new Y.Doc()
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))
    this.synced = new Promise((resolve) => (this._onSynced = resolve))
    this._connect()
  }

  _connect() {
    this.doc.on("update", this._localUpdate)
    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => this._onMessage(JSON.parse(event.data))
  }

  _localUpdate = (update, origin) => {
    if (origin === "remote") return
    const enc = encoding.createEncoder()
    encoding.writeVarUint(enc, MSG_SYNC)
    syncProtocol.writeUpdate(enc, update)
    this._send(enc)
  }

  _onMessage(msg) {
    if (msg.type === "welcome") {
      this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
    } else if (msg.type === "confirm_subscription") {
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeSyncStep1(enc, this.doc)
      this._send(enc)
      this._onSubscribed()
    } else if (msg.message?.m) {
      const decoder = decoding.createDecoder(fromBase64(msg.message.m))
      while (decoding.hasContent(decoder)) {
        if (decoding.readVarUint(decoder) === MSG_SYNC) {
          const enc = encoding.createEncoder()
          encoding.writeVarUint(enc, MSG_SYNC)
          const type = syncProtocol.readSyncMessage(decoder, enc, this.doc, "remote")
          if (encoding.length(enc) > 1) this._send(enc)
          if (type === syncProtocol.messageYjsSyncStep2) this._onSynced()
        } else {
          decoding.readVarUint8Array(decoder) // skip awareness
        }
      }
    }
  }

  _send(encoder) {
    if (this.ws.readyState !== WebSocket.OPEN) return
    this.ws.send(
      JSON.stringify({
        command: "message",
        identifier: this.identifier,
        data: JSON.stringify({ m: toBase64(encoding.toUint8Array(encoder)) }),
      })
    )
  }

  edit(text) {
    const fragment = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      const p = new Y.XmlElement("paragraph")
      p.insert(0, [new Y.XmlText(text)])
      fragment.insert(fragment.length, [p])
    })
  }

  has(text) {
    return this.doc.getXmlFragment("default").toString().includes(text)
  }

  // Drop the socket but keep the doc (offline). reconnect() rejoins and the
  // sync handshake reconciles in both directions.
  goOffline() {
    this.doc.off("update", this._localUpdate)
    this.ws.close()
  }

  reconnect() {
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))
    this.synced = new Promise((resolve) => (this._onSynced = resolve))
    this._connect()
    return this.subscribed
  }

  close() {
    this.ws.close()
  }
}

const control = (room, params) => {
  const qs = new URLSearchParams(params).toString()
  return fetch(`${BASE}/docs/${room}/audit/control?${qs}`, { method: "POST" })
}
const auditLog = async (room) => (await fetch(`${BASE}/docs/${room}/audit`)).json()
const serverText = async (room) => {
  const res = await fetch(`${BASE}/docs/${room}/content`)
  if (res.status !== 200) return ""
  const json = await res.json()
  return (json.content || []).flatMap((n) => (n.content || []).map((t) => t.text)).join("\n")
}

// === Scenario 1: slow store — invisible until stored =======================

async function slowStore() {
  console.log("\n--- Scenario 1: no one sees a change until it's stored ---")
  const room = `slow-${process.pid}`
  await control(room, { reset: 1, delay_ms: 1500 })

  const a = new Client(room)
  const b = new Client(room)
  await Promise.all([a.subscribed, b.subscribed])
  await sleep(150)

  a.edit("SECRET-MARKER") // server's on_change will block ~1.5s

  await sleep(400) // mid-store window
  check("originating client has its own optimistic edit", a.has("SECRET-MARKER"))
  check("other connected client does NOT see it yet", !b.has("SECRET-MARKER"))
  check("server /content does NOT show it yet", !(await serverText(room)).includes("SECRET-MARKER"))

  const c = new Client(room) // a fresh client resyncing during the store window
  await c.subscribed
  await c.synced
  await sleep(150)
  check("a fresh client's resync does NOT receive it (back door closed)", !c.has("SECRET-MARKER"))
  check("audit log is still empty mid-store", (await auditLog(room)).count === 0)

  await sleep(1500) // let the store finish
  check("connected client sees it after it's stored", b.has("SECRET-MARKER"))
  check("server /content shows it after it's stored", (await serverText(room)).includes("SECRET-MARKER"))
  check("audit log has exactly one entry", (await auditLog(room)).count === 1)

  a.close(); b.close(); c.close()
}

// === Scenario 2: store failure leaks nothing ===============================

async function storeFailure() {
  console.log("\n--- Scenario 2: a failed store leaks nothing ---")
  const room = `fail-${process.pid}`
  await control(room, { reset: 1, fail_once: 1 })

  const a = new Client(room)
  const b = new Client(room)
  await Promise.all([a.subscribed, b.subscribed])
  await sleep(150)

  a.edit("DOOMED-EDIT") // server's on_change raises for this one
  await sleep(600)

  check("other client never saw the failed change", !b.has("DOOMED-EDIT"))
  check("server /content does not contain it", !(await serverText(room)).includes("DOOMED-EDIT"))
  check("audit log does not contain it", (await auditLog(room)).count === 0)
  check("originating client still holds it locally (diverged)", a.has("DOOMED-EDIT"))

  a.close(); b.close()
  return room
}

// === Scenario 3: self-heal on reconnect ====================================

async function selfHeal() {
  console.log("\n--- Scenario 3: self-heal after a failed store ---")
  const room = `heal-${process.pid}`
  await control(room, { reset: 1, fail_once: 1 })

  const a = new Client(room)
  const b = new Client(room)
  await Promise.all([a.subscribed, b.subscribed])
  await sleep(150)

  a.edit("HEAL-ME") // fails to store; not applied/broadcast
  await sleep(500)
  check("change is absent after the failed store", (await auditLog(room)).count === 0)
  check("other client does not have it yet", !b.has("HEAL-ME"))

  // Store has recovered (fail_once already consumed). Client reconnects and
  // re-offers the missing edit via the sync handshake.
  await a.reconnect()
  await a.synced
  await sleep(500)

  check("after reconnect, the change is now recorded", (await auditLog(room)).count === 1)
  check("server /content now shows it", (await serverText(room)).includes("HEAL-ME"))
  check("the other client now receives it", b.has("HEAL-ME"))

  a.close(); b.close()
}

// === Scenario 4: offline edits recorded on reconnect handshake =============

async function offlineCatchUp() {
  console.log("\n--- Scenario 4: offline edits recorded on reconnect ---")
  const room = `offline-${process.pid}`
  await control(room, { reset: 1 })

  const a = new Client(room)
  await a.subscribed
  await sleep(150)

  a.edit("online-1")
  await sleep(300)
  check("online edit recorded (1 entry)", (await auditLog(room)).count === 1)

  a.goOffline()
  await sleep(100)
  a.edit("offline-1")
  a.edit("offline-2") // two edits while disconnected

  await a.reconnect()
  await a.synced
  await sleep(500)

  const log = await auditLog(room)
  check("offline edits arrive as ONE merged diff (2 total entries)", log.count === 2)
  const text = await serverText(room)
  check("all edits present on the server after catch-up",
    text.includes("online-1") && text.includes("offline-1") && text.includes("offline-2"))

  // The audit log alone reconstructs the document.
  const replay = new Y.Doc()
  for (const entry of log.updates) Y.applyUpdate(replay, fromBase64(entry))
  const replayLen = replay.getXmlFragment("default").length
  check("audit-log replay reconstructs all three paragraphs", replayLen === 3)

  a.close()
}

// --- Run --------------------------------------------------------------------

await slowStore()
await storeFailure()
await selfHeal()
await offlineCatchUp()

console.log("")
if (failures > 0) {
  console.log(`FAILED — ${failures} check(s) failed`)
  process.exit(1)
}
console.log("PASS — every scenario held: no change is visible to anyone until it is stored")
process.exit(0)
