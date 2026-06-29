// Regenerates test/fixtures/yjs_fixtures.rb in full. The fixtures are static
// Y.js bytes captured from the real JS library so the Ruby/Rust port can be
// tested for byte-level interop without a JS runtime in the loop.
//
//   bun run test/fixtures/generate_fixtures.mjs > test/fixtures/yjs_fixtures.rb
//
// bun auto-installs the imports (yjs, lib0); with node, install them first.
import * as Y from "yjs"
import * as encoding from "lib0/encoding"

const b64 = (u8) => Buffer.from(u8).toString("base64")

// Fixture 1: text "hello world" from client 1, in field "content".
const helloWorld = (() => {
  const doc = new Y.Doc()
  doc.clientID = 1
  doc.getText("content").insert(0, "hello world")
  return { update: b64(Y.encodeStateAsUpdate(doc)), sv: b64(Y.encodeStateVector(doc)) }
})()

// Fixture 2: two single-client docs, then merged into one.
const twoDocs = (() => {
  const d1 = new Y.Doc(); d1.clientID = 1; d1.getText("content").insert(0, "from doc1")
  const d2 = new Y.Doc(); d2.clientID = 2; d2.getText("content").insert(0, "from doc2")
  const u1 = Y.encodeStateAsUpdate(d1)
  const u2 = Y.encodeStateAsUpdate(d2)
  Y.applyUpdate(d1, u2)
  Y.applyUpdate(d2, u1)
  return { doc1: b64(u1), doc2: b64(u2), merged: b64(Y.encodeStateAsUpdate(d1)), mergedSv: b64(Y.encodeStateVector(d1)) }
})()

// Fixture 3: the y-websocket sync handshake. doc2 (empty) sends its state
// vector; doc1 replies with the diff that brings doc2 up to date.
const syncProtocol = (() => {
  const d1 = new Y.Doc(); d1.clientID = 1; d1.getText("content").insert(0, "synced content")
  const d2 = new Y.Doc(); d2.clientID = 2
  const sv2 = Y.encodeStateVector(d2)
  const diff = Y.encodeStateAsUpdate(d1, sv2)
  Y.applyUpdate(d2, diff)
  return { initialSv: b64(sv2), diff: b64(diff), finalSv: b64(Y.encodeStateVector(d1)) }
})()

// Fixture 4: a brand-new empty doc's state vector and update.
const emptyDoc = (() => {
  const doc = new Y.Doc()
  return { sv: b64(Y.encodeStateVector(doc)), update: b64(Y.encodeStateAsUpdate(doc)) }
})()

// Fixture 5: three causally-dependent updates from one client, insert "A",
// then "B", then "C", each in its own transaction so each update is the
// incremental delta that references the previous item.
const causalChain = (() => {
  const doc = new Y.Doc()
  doc.clientID = 1
  const updates = []
  doc.on("update", (u) => updates.push(b64(u)))
  const t = doc.getText("content")
  t.insert(0, "A")
  t.insert(1, "B")
  t.insert(2, "C")
  return updates // [U1, U2, U3]
})()

// Fixture 6: five independent from-scratch updates from distinct clients (1..5).
const concurrentClients = (() => {
  return Array.from({ length: 5 }, (_, i) => {
    const c = i + 1
    const doc = new Y.Doc()
    doc.clientID = c
    doc.getText("content").insert(0, `client-${c}-content`)
    return b64(Y.encodeStateAsUpdate(doc))
  })
})()

// Fixture 7: a real awareness (presence) message frame, client 42 with a user
// and cursor, exactly as a browser client emits it: MSG_AWARENESS (1) wrapping
// an encoded awareness update.
const presence = (() => {
  // The awareness update y-protocols emits for one client: count, clientID,
  // clock, then the JSON state. We build it directly so this generator needs
  // only yjs + lib0 (no y-protocols, whose lib0/webcrypto dep is awkward to
  // auto-install).
  const state = JSON.stringify({ cursor: { x: 10, y: 20 }, user: "alice" })
  const awUpdate = encoding.createEncoder()
  encoding.writeVarUint(awUpdate, 1) // one client
  encoding.writeVarUint(awUpdate, 42) // clientID
  encoding.writeVarUint(awUpdate, 1) // clock (first state set)
  encoding.writeVarString(awUpdate, state)

  const frame = encoding.createEncoder()
  encoding.writeVarUint(frame, 1) // MSG_AWARENESS
  encoding.writeVarUint8Array(frame, encoding.toUint8Array(awUpdate))
  return b64(encoding.toUint8Array(frame))
})()

const fixtures = `# frozen_string_literal: true

# Y.js Test Fixtures for yrby, static bytes captured from the real Y.js
# library so the Ruby/Rust port can be tested for byte-level interop.
# Regenerate with: bun run test/fixtures/generate_fixtures.mjs > test/fixtures/yjs_fixtures.rb

module YjsFixtures
  def self.b64(str)
    str.unpack1("m0")
  end

  # Fixture 1: Text with 'hello world' (client_id=1, field='content')
  module TextHelloWorld
    CLIENT_ID = 1
    UPDATE = YjsFixtures.b64("${helloWorld.update}")
    STATE_VECTOR = YjsFixtures.b64("${helloWorld.sv}")
  end

  # Fixture 2: Two docs merged
  # doc1 (client_id=1): content = "from doc1"
  # doc2 (client_id=2): content = "from doc2"
  module TwoDocsMerged
    DOC1_UPDATE = YjsFixtures.b64("${twoDocs.doc1}")
    DOC2_UPDATE = YjsFixtures.b64("${twoDocs.doc2}")
    MERGED_UPDATE = YjsFixtures.b64("${twoDocs.merged}")
    MERGED_STATE_VECTOR = YjsFixtures.b64("${twoDocs.mergedSv}")
  end

  # Fixture 3: Sync protocol test
  # doc1 (client_id=1): content = "synced content"
  # doc2 (client_id=2): empty, then synced
  module SyncProtocol
    INITIAL_SV_DOC2 = YjsFixtures.b64("${syncProtocol.initialSv}")
    DIFF_UPDATE = YjsFixtures.b64("${syncProtocol.diff}")
    FINAL_SV = YjsFixtures.b64("${syncProtocol.finalSv}")
  end

  # Fixture 4: Empty doc baseline
  module EmptyDoc
    STATE_VECTOR = YjsFixtures.b64("${emptyDoc.sv}")
    UPDATE = YjsFixtures.b64("${emptyDoc.update}")
  end

  # Fixture 5: three causally-dependent updates from one client, insert "A",
  # then "B", then "C". Each update references the previous item, so U3 cannot
  # integrate unless U2 has been applied first (it parks as a pending struct).
  module CausalChain
    U1 = YjsFixtures.b64("${causalChain[0]}")
    U2 = YjsFixtures.b64("${causalChain[1]}")
    U3 = YjsFixtures.b64("${causalChain[2]}")
  end

  # Fixture 6: five independent, from-scratch updates from distinct clients
  # (1..5). No cross-dependencies, so any receive order integrates; applying all
  # five converges to a state vector covering all five clients. Used by the
  # store-backed concurrency specs.
  module ConcurrentClients
    FIVE = [
      YjsFixtures.b64("${concurrentClients[0]}"),
      YjsFixtures.b64("${concurrentClients[1]}"),
      YjsFixtures.b64("${concurrentClients[2]}"),
      YjsFixtures.b64("${concurrentClients[3]}"),
      YjsFixtures.b64("${concurrentClients[4]}")
    ].freeze
  end

  # Fixture 7: a valid awareness (presence) message frame, client 42 with a
  # user + cursor. The server only ever relays such frames opaquely
  # (message_kind => 3); it never originates presence. So tests use this canned
  # frame instead of generating one server-side.
  module Presence
    FRAME = YjsFixtures.b64("${presence}")
  end
end
`

process.stdout.write(fixtures)
