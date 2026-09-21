import test from "node:test"
import assert from "node:assert/strict"
import Y from "ywasm"
import { createRubyHost } from "../src/ruby-host.js"

const tick = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }
function consumer() {
  const cable = { connects: 0, disconnects: 0, records: [] }
  cable.connect = () => { cable.connects++ }
  cable.disconnect = () => { cable.disconnects++ }
  cable.subscriptions = { create(params, handlers) {
    const record = { params, unsubscribed: 0, send() {}, unsubscribe() { this.unsubscribed++ } }
    cable.records.push(record)
    handlers.connected()
    return record
  } }
  return cable
}

test("Ruby host calls a Rails-compatible consumer factory without JSON options", async () => {
  const cable = consumer()
  let argumentsSeen
  const host = createRubyHost({ Y, createConsumer(...args) { argumentsSeen = args; return cable } })
  const client = host.createClient('{"channel":"Y::DocumentChannel","params":{"name":"room","grant":"token"}}')
  try {
    assert.deepEqual(argumentsSeen, [], "ActionCable createConsumer expects an optional URL, not client options")
    client.connect(); await tick()
    assert.equal(cable.connects, 1)
    assert.deepEqual(cable.records[0].params, { channel: "Y::DocumentChannel", name: "room", grant: "token" })
  } finally { client.destroy(); await tick() }
  assert.equal(cable.disconnects, 1)
})

test("Ruby JSON cannot take ownership of a shared consumer or replace host Yrs", async () => {
  const cable = consumer()
  let factoryCalls = 0
  const host = createRubyHost({ Y, consumer: cable, createConsumer() { factoryCalls++; return consumer() } })
  const options = JSON.stringify({ manageConsumer: true, Y: null, consumer: null, params: { id: "board" } })
  const first = host.createClient(options)
  const second = host.createClient(options)
  try {
    first.connect(); second.connect(); await tick()
    first.destroy(); await tick()
    assert.equal(factoryCalls, 0)
    assert.equal(cable.connects, 0)
    assert.equal(cable.disconnects, 0)
    assert.equal(cable.records[0].unsubscribed, 1)
    assert.equal(cable.records[1].unsubscribed, 0)
    assert.equal(second.status, "connected")
  } finally { first.destroy(); second.destroy(); await tick() }
  assert.equal(cable.disconnects, 0)
})

test("Ruby JSON cannot disable ownership for a factory-created consumer", async () => {
  const cable = consumer()
  const host = createRubyHost({ Y, createConsumer: () => cable })
  const client = host.createClient('{"manageConsumer":false,"consumer":null}')
  client.connect(); await tick()
  client.destroy(); await tick()
  assert.equal(cable.connects, 1)
  assert.equal(cable.disconnects, 1)
})

test("host validates options before allocation and releases owned consumers on creation failure", () => {
  const cable = consumer()
  let factoryCalls = 0
  const host = createRubyHost({ Y, createConsumer() { factoryCalls++; return cable } })
  for (const options of [null, {}, "null", "[]", "broken JSON"]) {
    assert.throws(() => host.createClient(options))
  }
  assert.equal(factoryCalls, 0)
  assert.throws(() => host.createClient('{"channel":3}'), /channel name/)
  assert.equal(factoryCalls, 1)
  assert.equal(cable.disconnects, 1)
})
