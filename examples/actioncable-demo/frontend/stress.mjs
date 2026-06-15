// Concurrent stress test: a storm of WebSocket clients hammering the server.
//
//   1. Boot with headroom:  RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777
//   2. Run:                 cd frontend && bun stress.mjs
//
// Tunables: CLIENTS=30 ROOMS=4 EDITS=40 KILLERS=4 LATE=4 POLLERS=2
//
// Scenario per room:
//   - CLIENTS/ROOMS clients connect concurrently (concurrent registry creation)
//   - every client runs an edit storm: EDITS inserts at random offsets in a
//     shared paragraph, each tagged with a unique token, plus awareness churn
//   - LATE clients join mid-storm and must catch up
//   - KILLERS finish their edits, then drop the socket abruptly mid-traffic
//   - POLLERS hit GET /docs/:id/content (server-side read) during the
//     storm: concurrent native readers against concurrent writers
//   - afterward, a fresh verifier client syncs from the server alone
//
// Checks, per room: all docs (survivors plus a fresh verifier that syncs from
// the server alone) converge byte-for-byte, and characters are conserved, so
// total text length equals the sum of all inserted token lengths and nothing
// was lost or applied twice. Token substrings aren't asserted, since concurrent
// inserts at random offsets can legally interleave inside other clients' runs.
import * as Y from "yjs"
import * as awarenessProtocol from "y-protocols/awareness"
import * as syncProtocol from "y-protocols/sync"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { serverText } from "./server_read.mjs"

const PORT = process.env.PORT || 3777
const CLIENTS = parseInt(process.env.CLIENTS || "30", 10)
const ROOMS = parseInt(process.env.ROOMS || "4", 10)
const EDITS = parseInt(process.env.EDITS || "40", 10)
const KILLERS = parseInt(process.env.KILLERS || "4", 10)
const LATE = parseInt(process.env.LATE || "4", 10)
const POLLERS = parseInt(process.env.POLLERS || "2", 10)
const CHURN = parseInt(process.env.CHURN || "4", 10)
const RUN = `s${Date.now().toString(36)}`

const MSG_SYNC = 0
const MSG_AWARENESS = 1
const toBase64 = (bytes) => Buffer.from(bytes).toString("base64")
const fromBase64 = (b64) => new Uint8Array(Buffer.from(b64, "base64"))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

let messagesSent = 0
let messagesReceived = 0

class StressClient {
  constructor(room, name) {
    this.room = room
    this.name = name
    this.doc = new Y.Doc()
    this.awareness = new awarenessProtocol.Awareness(this.doc)
    this.identifier = JSON.stringify({ channel: "DocumentChannel", id: room })
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))
    this.closed = false

    this.doc.on("update", (update, origin) => {
      if (origin === "remote") return
      const enc = encoding.createEncoder()
      encoding.writeVarUint(enc, MSG_SYNC)
      syncProtocol.writeUpdate(enc, update)
      this.send(enc)
    })

    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => this.onMessage(JSON.parse(event.data))
    this.ws.onerror = (e) => {
      if (!this.closed) throw new Error(`${this.name}: websocket error ${e.message || e}`)
    }
  }

  onMessage(msg) {
    switch (msg.type) {
      case "welcome":
        this.ws.send(JSON.stringify({ command: "subscribe", identifier: this.identifier }))
        return
      case "confirm_subscription": {
        const enc = encoding.createEncoder()
        encoding.writeVarUint(enc, MSG_SYNC)
        syncProtocol.writeSyncStep1(enc, this.doc)
        this.send(enc)
        this._onSubscribed()
        return
      }
      case "ping":
      case "disconnect":
        return
    }
    if (msg.message?.m) {
      messagesReceived++
      this.receiveBinary(fromBase64(msg.message.m))
    }
  }

  receiveBinary(bytes) {
    const decoder = decoding.createDecoder(bytes)
    while (decoding.hasContent(decoder)) {
      const type = decoding.readVarUint(decoder)
      if (type === MSG_SYNC) {
        const enc = encoding.createEncoder()
        encoding.writeVarUint(enc, MSG_SYNC)
        syncProtocol.readSyncMessage(decoder, enc, this.doc, "remote")
        if (encoding.length(enc) > 1) this.send(enc)
      } else if (type === MSG_AWARENESS) {
        awarenessProtocol.applyAwarenessUpdate(
          this.awareness,
          decoding.readVarUint8Array(decoder),
          "remote"
        )
      } else {
        throw new Error(`${this.name}: unknown message type ${type}`)
      }
    }
  }

  send(encoder) {
    if (this.closed || this.ws.readyState !== WebSocket.OPEN) return
    messagesSent++
    this.ws.send(
      JSON.stringify({
        command: "message",
        identifier: this.identifier,
        data: JSON.stringify({ m: toBase64(encoding.toUint8Array(encoder)) }),
      })
    )
  }

  text() {
    return this.doc.getXmlFragment("default").toString()
  }

  // Insert a uniquely-tagged token at a random offset in the shared paragraph.
  edit(round) {
    const fragment = this.doc.getXmlFragment("default")
    this.doc.transact(() => {
      if (fragment.length === 0) fragment.insert(0, [new Y.XmlElement("paragraph")])
      const paragraph = fragment.get(0)
      if (paragraph.length === 0) paragraph.insert(0, [new Y.XmlText()])
      const ytext = paragraph.get(0)
      const token = `[${this.name}.${round}]`
      const offset = Math.floor(Math.random() * (ytext.length + 1))
      ytext.insert(offset, token)
    })
  }

  setPresence(round) {
    this.awareness.setLocalState({ user: { name: this.name }, round })
    const enc = encoding.createEncoder()
    encoding.writeVarUint(enc, MSG_AWARENESS)
    encoding.writeVarUint8Array(
      enc,
      awarenessProtocol.encodeAwarenessUpdate(this.awareness, [this.doc.clientID])
    )
    this.send(enc)
  }

  async storm() {
    // Churn clients drop mid-storm, keep editing offline for 10 rounds, then
    // reconnect, and the step1/step2 handshake has to merge both directions.
    const offlineAt = this.churn ? Math.floor(EDITS / 2) : -1
    for (let round = 0; round < EDITS; round++) {
      if (round === offlineAt) this.ws.close()
      if (round === offlineAt + 10) await this.reconnect()
      this.edit(round)
      if (round % 5 === 0) this.setPresence(round)
      await sleep(Math.random() * 10)
    }
    if (this.churn) await this.flushOffline()
  }

  async reconnect() {
    this.subscribed = new Promise((resolve) => (this._onSubscribed = resolve))
    this.ws = new WebSocket(`ws://localhost:${PORT}/cable`, ["actioncable-v1-json"])
    this.ws.onmessage = (event) => this.onMessage(JSON.parse(event.data))
    this.ws.onerror = (e) => {
      if (!this.closed) throw new Error(`${this.name}: websocket error ${e.message || e}`)
    }
    await this.subscribed
    this.reconnected = true
  }

  // Edits made while offline were never sent as live updates; they reach the
  // server through the post-reconnect step1/step2 exchange (the server's
  // step1 arrives on subscribe; our step2 reply carries the offline work).
  async flushOffline() {
    const enc = encoding.createEncoder()
    encoding.writeVarUint(enc, MSG_SYNC)
    syncProtocol.writeSyncStep1(enc, this.doc)
    this.send(enc)
  }

  close() {
    this.closed = true
    this.ws.close()
  }
}

// --- Run --------------------------------------------------------------------

console.log(
  `storm: ${CLIENTS} clients, ${ROOMS} rooms, ${EDITS} edits each, ` +
    `${LATE} late joiners, ${KILLERS} abrupt disconnects, ${CHURN} offline-reconnectors, ` +
    `${POLLERS} HTTP pollers/room`
)
const startedAt = Date.now()
const rooms = Array.from({ length: ROOMS }, (_, r) => `${RUN}-room${r}`)
const clientsByRoom = new Map(rooms.map((room) => [room, []]))
const expectedTokens = new Map(rooms.map((room) => [room, []]))

// Connect everyone concurrently (stresses concurrent registry creation).
const initialClients = Array.from({ length: CLIENTS }, (_, i) => {
  const room = rooms[i % ROOMS]
  const client = new StressClient(room, `c${i}`)
  clientsByRoom.get(room).push(client)
  return client
})
await Promise.all(initialClients.map((c) => c.subscribed))
console.log(`ok: ${CLIENTS} clients connected and subscribed concurrently`)

// Churn clients (disjoint from killers) reconnect mid-storm with offline edits.
initialClients.slice(KILLERS, KILLERS + CHURN).forEach((c) => (c.churn = true))

// HTTP pollers hammer server-side read during the storm.
let polling = true
let pollCount = 0
let pollErrors = 0
const pollers = rooms.flatMap((room) =>
  Array.from({ length: POLLERS }, async () => {
    while (polling) {
      const res = await fetch(`http://localhost:${PORT}/docs/${room}/content`)
      // 422 "no content yet" is legal in the opening instants; 5xx never is.
      if (res.status >= 500) pollErrors++
      await res.text()
      pollCount++
    }
  })
)

// The storm: everyone edits at once; late joiners and killers mixed in.
const storms = initialClients.map((c) => c.storm())

const lateJoiners = []
const latePromise = (async () => {
  await sleep(150) // mid-storm
  for (let i = 0; i < LATE; i++) {
    const room = rooms[i % ROOMS]
    const client = new StressClient(room, `late${i}`)
    clientsByRoom.get(room).push(client)
    lateJoiners.push(client)
    await client.subscribed
    await client.storm() // late joiners edit too
  }
})()

await Promise.all([...storms, latePromise])
console.log("ok: edit storm complete")

// Abrupt disconnects: killers' edits are already sent; they vanish mid-traffic.
const killers = initialClients.slice(0, KILLERS)
await sleep(300) // let their last frames flush through the cable
killers.forEach((c) => c.close())
console.log(`ok: ${KILLERS} clients dropped abruptly`)

// Every client expects every token from every client in its room.
for (const room of rooms) {
  for (const client of clientsByRoom.get(room)) {
    for (let round = 0; round < EDITS; round++) {
      expectedTokens.get(room).push(`[${client.name}.${round}]`)
    }
  }
}

// Quiesce, then verify with fresh clients that sync from the server alone.
const survivors = (room) => clientsByRoom.get(room).filter((c) => !c.closed)

const waitFor = async (label, predicate, timeoutMs = 20000, diagnose = null) => {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await sleep(100)
  }
  if (diagnose) diagnose()
  throw new Error(`TIMEOUT: ${label}`)
}

// Visible characters only. Concurrent inserts legally split each other's runs,
// so we assert character conservation rather than token substrings.
const visibleChars = (s) => s.replace(/<[^>]+>/g, "").length

// On failure: per-client character deficit and whether updates are queued
// as pending (= a dependency never arrived).
const diagnoseRoom = (room, expectedChars) => {
  for (const client of survivors(room)) {
    const chars = visibleChars(client.text())
    const pending = client.doc.store.pendingStructs
    const pendingClients = pending
      ? [...pending.missing.keys()].map((id) => `client ${id} (needs clock ${pending.missing.get(id)})`)
      : []
    if (chars !== expectedChars || pendingClients.length > 0) {
      console.error(
        `  ${client.name}: ${chars}/${expectedChars} chars; ` +
          `pending deps: ${pendingClients.join(", ") || "none"}`
      )
    }
  }
}

for (const room of rooms) {
  const tokens = expectedTokens.get(room)
  // Character conservation: every doc must hold exactly the characters of
  // every token inserted by every client (including killed ones), with no loss
  // and nothing applied twice.
  const expectedChars = tokens.reduce((sum, t) => sum + t.length, 0)

  await waitFor(
    `${room}: survivors converge on all ${expectedChars} chars from ${tokens.length} edits`,
    () => survivors(room).every((c) => visibleChars(c.text()) === expectedChars),
    20000,
    () => diagnoseRoom(room, expectedChars)
  )

  const verifier = new StressClient(room, "verifier")
  await verifier.subscribed
  await waitFor(
    `${room}: verifier syncs from server alone`,
    () => visibleChars(verifier.text()) === expectedChars,
    20000,
    () => diagnoseRoom(room, expectedChars)
  )

  // Byte-for-byte convergence across every doc, including the verifier.
  const reference = Y.encodeStateAsUpdate(verifier.doc)
  const referenceText = verifier.text()
  for (const client of survivors(room)) {
    const state = Y.encodeStateAsUpdate(client.doc)
    if (state.length !== reference.length || !state.every((b, i) => b === reference[i])) {
      throw new Error(`${room}: ${client.name} diverged from verifier (state encoding)`)
    }
    if (client.text() !== referenceText) {
      throw new Error(`${room}: ${client.name} diverged from verifier (text)`)
    }
  }

  // The server's CRDT state sees the same converged content.
  const serverDocText = await serverText(`http://localhost:${PORT}`, room)
  const extractedLength = serverDocText.length
  if (extractedLength !== expectedChars) {
    throw new Error(
      `${room}: server state has ${extractedLength}/${expectedChars} chars: ${serverDocText.slice(0, 200)}`
    )
  }

  verifier.close()
  console.log(
    `ok: ${room} with ${tokens.length} edits / ${expectedChars} chars conserved, ` +
      `${survivors(room).length + 1} docs byte-identical, server state matches`
  )
}

polling = false
await Promise.all(pollers)
if (pollErrors > 0) throw new Error(`${pollErrors} /content requests returned 5xx`)

for (const room of rooms) clientsByRoom.get(room).forEach((c) => c.close())

const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
console.log(
  `\nPASS in ${elapsed}s: ${messagesSent} cable messages sent, ${messagesReceived} received, ` +
    `${pollCount} concurrent /content reads (0 server errors)`
)
process.exit(0)
