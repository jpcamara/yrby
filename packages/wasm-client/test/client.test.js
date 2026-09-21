import test from "node:test"
import assert from "node:assert/strict"
import Y from "ywasm"
import * as JSY from "yjs"
import { Awareness, applyAwarenessUpdate, encodeAwarenessUpdate } from "y-protocols/awareness"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { toBase64, fromBase64 } from "yrby-client/base64"
import { createClient, LOCAL_ORIGIN } from "../src/client.js"

const tick = async () => { for (let i = 0; i < 16; i++) await Promise.resolve() }
function frame(type, payload, subtype) {
  const writer = encoding.createEncoder()
  encoding.writeVarUint(writer, type)
  if (subtype !== undefined) encoding.writeVarUint(writer, subtype)
  encoding.writeVarUint8Array(writer, payload)
  return encoding.toUint8Array(writer)
}
function unframe(bytes) {
  const reader = decoding.createDecoder(bytes)
  const type = decoding.readVarUint(reader)
  const subtype = type === 0 ? decoding.readVarUint(reader) : undefined
  return { type, subtype, payload: decoding.readVarUint8Array(reader) }
}

class Cable {
  constructor({ whisper = false, openingBeforeConnected = false } = {}) {
    this.doc = new JSY.Doc()
    this.awareness = new Awareness(this.doc)
    this.awareness.setLocalState(null)
    this.records = []
    this.sent = []
    this.whispers = []
    this.connectCount = 0
    this.disconnectCount = 0
    this.drop = false
    this.subscriptions = { create: (params, handlers) => {
      const record = { params, handlers, live: true, unsubscribed: 0 }
      record.send = message => { this.sent.push(message); this.receive(record, message) }
      record.unsubscribe = () => { record.live = false; record.unsubscribed++ }
      if (whisper) record.whisper = message => { this.whispers.push(message); this.receive(record, message) }
      this.records.push(record)
      if (openingBeforeConnected) handlers.received({ update: toBase64(frame(0, JSY.encodeStateVector(this.doc), 0)) })
      handlers.connected()
      return record
    } }
  }
  connect() { this.connectCount++ }
  disconnect() { this.disconnectCount++ }
  receive(record, message) {
    if (this.drop || !record.live) return
    const bytes = fromBase64(message.awareness ?? message.update)
    const { type, subtype, payload } = unframe(bytes)
    if (type === 1) applyAwarenessUpdate(this.awareness, payload, record)
    else if (subtype === 0) {
      record.handlers.received({ update: toBase64(frame(0, JSY.encodeStateAsUpdate(this.doc, payload), 1)) })
      record.handlers.received({ update: toBase64(frame(0, JSY.encodeStateVector(this.doc), 0)) })
    } else {
      JSY.applyUpdate(this.doc, payload)
      for (const other of this.records) {
        if (other !== record && other.live) other.handlers.received({ update: toBase64(frame(0, payload, 2)) })
      }
    }
    if (message.id !== undefined) record.handlers.received({ ack: message.id })
  }
  destroy() { this.awareness.destroy(); this.doc.destroy() }
}

function setup(t, options = {}, cableOptions = {}) {
  const cable = new Cable(cableOptions)
  const errors = []
  const client = createClient({ Y, consumer: cable, onError: (error, context) => errors.push({ error, context }), ...options })
  t.after(() => { client.destroy(); cable.destroy() })
  return { client, cable, errors }
}

test("generic maps, text, and arrays share V1 updates with Yjs", async t => {
  const { client, cable } = setup(t)
  const map = client.map("settings")
  const text = client.text("caption")
  const array = client.array("layers")
  map.setJSON("palette", JSON.stringify({ colors: ["ruby", "gold"], visible: true }))
  map.setJSON("nil", "null")
  assert.equal(map.has("nil"), true)
  assert.equal(map.has("missing"), false)
  text.insert(0, "Hi 💎")
  assert.equal(text.length, 5, "text indexes use UTF-16, like Yjs")
  text.insert(5, "!")
  array.insertJSON(0, '["scene", {"name":"paint"}]')
  client.connect()
  await client.whenSynced
  await client.whenAcknowledged
  assert.deepEqual(cable.doc.getMap("settings").toJSON(), JSON.parse(map.readJSON()))
  assert.equal(cable.doc.getText("caption").toString(), "Hi 💎!")
  assert.deepEqual(cable.doc.getArray("layers").toJSON(), ["scene", { name: "paint" }])
  text.delete(2, 3)
  array.delete(0, 1)
  map.delete("nil")
  await tick()
  assert.equal(cable.doc.getText("caption").toString(), "Hi!")
  assert.deepEqual(JSON.parse(array.getJSON(0)), { name: "paint" })
  assert.deepEqual(JSON.parse(map.keysJSON()), ["palette"])
  assert.equal(client.hasPending, false)
})

test("transactions batch edits and defer callbacks until Ruby can safely re-enter", async t => {
  const { client } = setup(t)
  const map = client.map("shared")
  const array = client.array("items")
  const text = client.text("text")
  let calls = 0
  client.onChange(() => {
    calls++
    assert.equal(map.getJSON("one"), "1")
    assert.equal(text.toString(), "ruby")
  })
  client.beginTransaction("gesture")
  map.setJSON("one", "1")
  array.insertJSON(0, "[1,2,3]")
  text.insert(0, "ruby")
  assert.equal(map.getJSON("one"), "1")
  assert.throws(() => client.map("new-while-locked"), /active transaction/)
  assert.throws(() => client.beginTransaction(), /active transaction/)
  client.endTransaction()
  assert.equal(client.hasPending, true, "pending is visible before deferred delivery")
  assert.equal(calls, 0)
  await tick()
  assert.equal(calls, 1)
  assert.equal(client.stats.localUpdates, 1)
})

test("remote/bootstrap updates and snapshots never echo as local changes", async t => {
  const { client, cable } = setup(t)
  const source = new JSY.Doc()
  source.getMap("remote").set("from", "server")
  client.applyRemoteUpdate(JSY.encodeStateAsUpdate(source))
  await tick()
  assert.equal(client.map("remote").getJSON("from"), '"server"')
  assert.equal(client.hasPending, false)
  assert.equal(client.pendingUpdate, null)
  assert.equal(client.stats.localUpdates, 0)
  assert.equal(cable.sent.length, 0)
  const snapshot = client.encodeStateAsUpdate()
  const clone = new JSY.Doc()
  JSY.applyUpdate(clone, snapshot)
  assert.equal(clone.getMap("remote").get("from"), "server")
  assert.ok(client.encodeStateVector() instanceof Uint8Array)
  source.destroy(); clone.destroy()
})

test("pending recovery retains an ack obligation even when already integrated", async t => {
  const { client, cable } = setup(t)
  client.map("data").setJSON("offline", "42")
  const tail = client.pendingUpdate
  const snapshot = client.encodeStateAsUpdate()
  assert.ok(tail instanceof Uint8Array)
  const restored = createClient({ Y, consumer: cable })
  t.after(() => restored.destroy())
  restored.applyRemoteUpdate(snapshot)
  assert.equal(restored.hasPending, false)
  restored.restorePendingUpdate(tail)
  assert.equal(restored.hasPending, true)
  restored.connect()
  await restored.whenSynced
  await restored.whenAcknowledged
  assert.equal(cable.doc.getMap("data").get("offline"), 42)
  assert.equal(restored.hasPending, false)
  assert.equal(restored.pendingUpdate, null)
})

test("lost updates, reconnects, and concurrent Yjs edits converge", async t => {
  const { client, cable } = setup(t)
  client.connect()
  await client.whenSynced
  const map = client.map("board")
  cable.drop = true
  map.setJSON("local", '"kept"')
  await tick()
  assert.equal(client.hasPending, true)
  assert.equal(cable.doc.getMap("board").get("local"), undefined)
  cable.records[0].handlers.disconnected()
  await tick()
  assert.equal(client.status, "connecting")
  cable.doc.getMap("board").set("remote", "also kept")
  map.setJSON("offline", "true")
  cable.drop = false
  cable.records[0].handlers.connected()
  await tick()
  await client.whenAcknowledged
  assert.deepEqual(JSON.parse(map.readJSON()), { local: "kept", offline: true, remote: "also kept" })
  assert.deepEqual(cable.doc.getMap("board").toJSON(), JSON.parse(map.readJSON()))
  assert.equal(client.status, "synced")
})

test("reliable retransmission keeps edits until a valid ack", async t => {
  const { client, cable } = setup(t)
  client.connect(); await client.whenSynced
  cable.drop = true
  client.map("map").setJSON("x", "1")
  await tick()
  for (const ack of ["1", NaN, -1, 999]) cable.records[0].handlers.received({ ack })
  await tick()
  assert.equal(client.hasPending, true)
  cable.drop = false
  client.delivery.onTick()
  await client.whenAcknowledged
  assert.equal(cable.doc.getMap("map").get("x"), 1)
  assert.equal(client.hasPending, false)
})

test("opening state vector before confirmation and synchronous callbacks are safe", async t => {
  const { client, cable, errors } = setup(t, {}, { openingBeforeConnected: true })
  cable.doc.getMap("data").set("server", true)
  client.map("data").setJSON("browser", "true")
  client.connect()
  await client.whenSynced
  await client.whenAcknowledged
  assert.deepEqual(JSON.parse(client.map("data").readJSON()), { browser: true, server: true })
  assert.equal(errors.length, 0)
})

test("undo only changes the scoped local origin, preserves other peers, and supports redo", async t => {
  const { client, cable } = setup(t)
  const paint = client.map("paint")
  const other = client.map("other")
  const undo = client.createUndoManager(["paint"], LOCAL_ORIGIN, 60_000)
  client.connect(); await client.whenSynced
  paint.setJSON("human", "1")
  other.setJSON("unscoped", "7")
  await tick()
  undo.stopCapturing()
  const remote = new JSY.Doc()
  remote.getMap("paint").set("peer", 2)
  client.applyRemoteUpdate(JSY.encodeStateAsUpdate(remote))
  await tick()
  assert.equal(undo.canUndo, true)
  undo.undo(); await tick()
  assert.deepEqual(JSON.parse(paint.readJSON()), { peer: 2 })
  assert.equal(other.getJSON("unscoped"), "7")
  assert.equal(undo.canRedo, true)
  undo.redo(); await tick()
  assert.deepEqual(JSON.parse(paint.readJSON()), { human: 1, peer: 2 })
  assert.equal(cable.doc.getMap("paint").get("human"), 1)
  undo.clear(); await tick()
  assert.equal(undo.canUndo, false)
  undo.destroy(); undo.destroy()
  remote.destroy()
})

test("shared consumers stay open, managed consumers close, stale callbacks are ignored", async t => {
  const { client, cable } = setup(t)
  const statuses = []
  client.onStatusChange(event => statuses.push(event.status))
  client.connect(); await client.whenSynced; await tick()
  const old = cable.records[0]
  client.disconnect(); client.connect(); await tick()
  old.handlers.rejected(); old.handlers.disconnected(); await tick()
  assert.equal(client.status, "synced")
  assert.equal(cable.connectCount, 0)
  assert.equal(cable.disconnectCount, 0)
  assert.equal(old.unsubscribed, 1)
  assert.ok(statuses.includes("synced"))
  const managed = createClient({ Y, consumer: cable, manageConsumer: true })
  managed.connect(); await managed.whenSynced
  managed.destroy(); await tick()
  assert.equal(cable.connectCount, 1)
  assert.equal(cable.disconnectCount, 1)
})

test("AnyCable whispers only presence; generic fields and removal use the standard codec", async t => {
  const { client, cable } = setup(t, { localState: { user: { name: "Ruby" }, tool: "brush" } }, { whisper: true })
  client.connect(); await client.whenSynced
  client.map("art").setJSON("pixel", "3")
  await client.whenAcknowledged
  assert.ok(cable.whispers.length > 0)
  assert.ok(cable.whispers.every(message => unframe(fromBase64(message.awareness)).type === 1))
  assert.ok(cable.sent.every(message => unframe(fromBase64(message.update)).type === 0))
  assert.equal(cable.awareness.getStates().get(client.clientID).tool, "brush")
  client.setPresenceJSON('{"cursor":{"x":4},"custom":true}')
  assert.deepEqual(cable.awareness.getStates().get(client.clientID), { cursor: { x: 4 }, custom: true })
  client.disconnect(); await tick()
  assert.equal(cable.awareness.getStates().has(client.clientID), false)
  client.connect(); await tick()
  assert.equal(cable.awareness.getStates().get(client.clientID).custom, true)
})

test("incoming awareness is not echoed and transport drops clear remote presence", async t => {
  const { client, cable } = setup(t)
  client.connect(); await client.whenSynced
  const peerDoc = new JSY.Doc()
  const peerAwareness = new Awareness(peerDoc)
  peerAwareness.setLocalState({ user: { name: "Other" }, color: "ruby" })
  const before = cable.sent.length
  cable.records[0].handlers.received({ update: toBase64(frame(1, encodeAwarenessUpdate(peerAwareness, [peerDoc.clientID]))) })
  await tick()
  assert.equal(JSON.parse(client.getStatus()).peers.some(peer => peer.user?.name === "Other"), true)
  assert.equal(cable.sent.length, before)
  cable.records[0].handlers.disconnected(); await tick()
  assert.equal(JSON.parse(client.getStatus()).peers.some(peer => peer.user?.name === "Other"), false)
  peerAwareness.destroy(); peerDoc.destroy()
})

test("invalid envelopes fail locally without corrupting the next valid update", async t => {
  const { client, cable, errors } = setup(t)
  client.connect(); await client.whenSynced
  cable.records[0].handlers.received({ update: toBase64(new Uint8Array([0, 2, 255])) })
  cable.records[0].handlers.received({ awareness: toBase64(frame(0, new Uint8Array([0]), 2)) })
  await tick()
  assert.equal(errors.length, 2)
  client.map("valid").setJSON("still", "true")
  await client.whenAcknowledged
  assert.equal(cable.doc.getMap("valid").get("still"), true)
})

test("JSON and range validation prevent malformed API input from trapping WASM", t => {
  const { client } = setup(t)
  const text = client.text("t")
  const array = client.array("a")
  const map = client.map("m")
  assert.throws(() => text.insert(-1, "bad"), RangeError)
  assert.throws(() => text.delete(0, 1), RangeError)
  assert.throws(() => array.insertJSON(0, "{}"), TypeError)
  assert.throws(() => map.setJSON("key", "undefined"), SyntaxError)
  assert.throws(() => client.setPresenceJSON("3"), TypeError)
  assert.throws(() => client.text("m"), /different type/)
  map.setJSON("fine", "true")
  assert.equal(map.getJSON("fine"), "true")
})

test("rejection blocks the subscription and renew uses updated channel params", async t => {
  const { client, cable, errors } = setup(t, { channel: "Y::DocumentChannel", params: { grant: "old", name: "board" } })
  client.connect(); await client.whenSynced
  cable.records[0].handlers.rejected(); await tick()
  assert.equal(client.status, "disconnected")
  assert.equal(errors.at(-1).context, "rejected")
  client.map("edits").setJSON("retained", "true")
  client.renew({ grant: "new" }); await tick()
  await client.whenAcknowledged
  assert.deepEqual(cable.records.at(-1).params, { channel: "Y::DocumentChannel", grant: "new", name: "board" })
  assert.equal(cable.doc.getMap("edits").get("retained"), true)
})

test("destroy is idempotent and subscriptions are cleaned up", async t => {
  const { client, cable } = setup(t)
  client.connect(); await client.whenSynced
  client.destroy(); client.destroy(); await tick()
  assert.equal(cable.records[0].unsubscribed, 1)
  assert.throws(() => client.connect(), /destroyed/)
  assert.throws(() => client.map("x"), /destroyed/)
})

test("text and array undo scopes use local history and explicit capture boundaries", async t => {
  const { client } = setup(t)
  const text = client.text("caption")
  const array = client.array("layers")
  const undo = client.createUndoManager([text, array], LOCAL_ORIGIN, 60_000)
  let changed = 0
  undo.onChange(() => { changed++ })
  client.beginTransaction()
  text.insert(0, "One")
  array.insertJSON(0, '["one"]')
  client.endTransaction()
  await tick()
  undo.stopCapturing()
  text.insert(text.length, " two")
  await tick()
  undo.undo(); await tick()
  assert.equal(text.toString(), "One")
  assert.deepEqual(JSON.parse(array.readJSON()), ["one"])
  undo.undo(); await tick()
  assert.equal(text.toString(), "")
  assert.deepEqual(JSON.parse(array.readJSON()), [])
  undo.redo(); await tick()
  assert.equal(text.toString(), "One")
  assert.ok(changed >= 3)
})

test("undo never deletes a peer's later change to the same map key", async t => {
  const { client, cable } = setup(t)
  const map = client.map("paint")
  const undo = client.createUndoManager([map])
  client.connect(); await client.whenSynced
  map.setJSON("cell", "1")
  await client.whenAcknowledged
  const before = client.encodeStateVector()
  cable.doc.getMap("paint").set("cell", 2)
  client.applyRemoteUpdate(JSY.encodeStateAsUpdate(cable.doc, before))
  await tick()
  undo.undo(); await tick()
  assert.equal(map.getJSON("cell"), "2")
})

test("malformed awareness is validated before applying any of its entries", async t => {
  const { client, cable, errors } = setup(t)
  client.connect(); await client.whenSynced
  const writer = encoding.createEncoder()
  encoding.writeVarUint(writer, 2)
  encoding.writeVarUint(writer, 123)
  encoding.writeVarUint(writer, 1)
  encoding.writeVarString(writer, '{"user":{"name":"partial"}}')
  encoding.writeVarUint(writer, 124)
  encoding.writeVarUint(writer, 1)
  encoding.writeVarString(writer, "not JSON")
  cable.records[0].handlers.received({ awareness: toBase64(frame(1, encoding.toUint8Array(writer))) })
  await tick()
  assert.equal(errors.length, 1)
  assert.equal(JSON.parse(client.getStatus()).peers.some(peer => peer.clientID === 123), false)
})

test("page cache suspend removes presence and resume preserves offline edits", async t => {
  const previousWindow = globalThis.window
  const page = new EventTarget()
  globalThis.window = page
  const cable = new Cable()
  const client = createClient({ Y, consumer: cable, localState: { user: { name: "Ruby" } } })
  t.after(() => { client.destroy(); cable.destroy(); globalThis.window = previousWindow })
  client.connect(); await client.whenSynced
  page.dispatchEvent(new Event("pagehide")); await tick()
  assert.equal(client.status, "disconnected")
  assert.equal(cable.awareness.getStates().has(client.clientID), false)
  client.map("art").setJSON("offline", "true")
  const show = new Event("pageshow")
  Object.defineProperty(show, "persisted", { value: true })
  page.dispatchEvent(show); await tick()
  await client.whenAcknowledged
  assert.equal(client.status, "synced")
  assert.equal(cable.doc.getMap("art").get("offline"), true)
  assert.equal(cable.awareness.getStates().get(client.clientID).user.name, "Ruby")
})
