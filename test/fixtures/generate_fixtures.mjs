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

// Fixture 9: a causal gap as two separate deltas. FIRST inserts "a" (client 1);
// DEPENDENT inserts "b" after it, so DEPENDENT depends on FIRST. Applied to a doc
// that lacks FIRST, DEPENDENT parks as a pending struct (empty state vector, no
// integrated content) -- the shape of legacy gappy data poisoning sync.
const gap = (() => {
  const updates = []
  const doc = new Y.Doc()
  doc.clientID = 1
  doc.on("update", u => updates.push(u))
  const t = doc.getText("notepad")
  t.insert(0, "a")
  t.insert(1, "b")

  // A second, independent gap from a DIFFERENT client (2): insert "x" then "y",
  // keep only the "y" delta. Applied on top of client 1's integrated content it
  // parks as pending *without* dropping the real content -- the mixed case.
  const other = []
  const d2 = new Y.Doc()
  d2.clientID = 2
  d2.on("update", u => other.push(u))
  const t2 = d2.getText("notepad")
  t2.insert(0, "x")
  t2.insert(1, "y")

  return { first: b64(updates[0]), dependent: b64(updates[1]), dependentOther: b64(other[1]) }
})()

// Fixture 10: a pending *delete set*. Client 3 inserts "z", then deletes it; we
// keep only the deletion delta. Applied to a doc without client 3's content, the
// delete set references a struct that isn't there, so it parks as a pending
// delete set (the delete-side counterpart to a pending struct).
const pendingDelete = (() => {
  const doc = new Y.Doc()
  doc.clientID = 3
  const t = doc.getText("notepad")
  t.insert(0, "z")
  const sv = Y.encodeStateVector(doc)
  t.delete(0, 1)
  return b64(Y.encodeStateAsUpdate(doc, sv)) // deletion only
})()

// Fixture 11: a cross-client-origin gap. Client 3 creates "abc"; client 1
// applies it and types between client 3's characters, so client 1's delta
// references client 3's blocks as origins. On a doc that lacks CONTENT, the
// per-client clock lower bound of DELTA passes (client 1 starts at clock 0) but
// integration parks -- the readiness case a clock-only check misses.
const crossClientOrigin = (() => {
  const c = new Y.Doc()
  c.clientID = 3
  c.getText("t").insert(0, "abc")
  const content = Y.encodeStateAsUpdate(c)

  const a = new Y.Doc()
  a.clientID = 1
  Y.applyUpdate(a, content)
  const sv = Y.encodeStateVector(a)
  a.getText("t").insert(1, "X") // between client 3's chars
  const delta = Y.encodeStateAsUpdate(a, sv) // only client 1's block
  return { content: b64(content), delta: b64(delta) }
})()

// Fixture 12: a flood of DISTINCT gappy updates (72 > GAP_STRIKE_MAX_KEYS=64).
// Each client 1000+i inserts twice and only the second delta is kept, so every
// update is gappy on a store that never saw the first -- and every one has
// unique bytes. Used to prove strike-table eviction can't be abused to reset a
// tracked key's count.
const gapFlood = (() => {
  return Array.from({ length: 72 }, (_, i) => {
    const updates = []
    const doc = new Y.Doc()
    doc.clientID = 1000 + i
    doc.on("update", (u) => updates.push(u))
    const t = doc.getText("flood")
    t.insert(0, "a")
    t.insert(1, "b")
    return b64(updates[1]) // depends on the (never-delivered) first delta
  })
})()

// Fixture 8: a deletion delivered as its own delta. Insert "hello" (client 1),
// snapshot that state, then delete the first char and capture the incremental
// update. The deletion diff carries only a delete set (no new structs), so
// re-applying it is a no-op -- the shape a lost-ack retry takes.
const deleteRetry = (() => {
  const doc = new Y.Doc()
  doc.clientID = 1
  const t = doc.getText("content")
  t.insert(0, "hello")
  const content = Y.encodeStateAsUpdate(doc)
  const sv = Y.encodeStateVector(doc)
  t.delete(0, 1) // delete "h"
  const deletion = Y.encodeStateAsUpdate(doc, sv) // just the deletion, as a diff
  return { content: b64(content), deletion: b64(deletion) }
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

  # Fixture 8: a deletion delivered as its own delta. CONTENT inserts "hello"
  # (client 1); DELETION is the incremental update that deletes the first char.
  # DELETION carries only a delete set (no new structs), so re-applying it is a
  # no-op -- the exactly-once guard records/broadcasts it once, then treats the
  # lost-ack retry as already-applied (acked, not re-recorded).
  module DeleteRetry
    CONTENT = YjsFixtures.b64("${deleteRetry.content}")
    DELETION = YjsFixtures.b64("${deleteRetry.deletion}")
  end

  # Fixture 9: a causal gap as two deltas. FIRST inserts "a" (client 1); DEPENDENT
  # inserts "b" after it. Applied without FIRST, DEPENDENT parks as a pending
  # struct (empty state vector, no integrated content) -- legacy gappy data that
  # poisons sync if served. Healed by later applying FIRST.
  module Gap
    FIRST = YjsFixtures.b64("${gap.first}")
    DEPENDENT = YjsFixtures.b64("${gap.dependent}")
    # A gappy insert from a different client (2), for the "integrated content plus
    # pending" mixed case (applied on top of FIRST's integrated "a").
    DEPENDENT_OTHER = YjsFixtures.b64("${gap.dependentOther}")
  end

  # Fixture 10: a pending *delete set* -- a deletion delta whose target struct the
  # doc doesn't have, so it parks as a pending delete set (delete-side counterpart
  # to a pending struct). See DeleteRetry for a fully-integrated deletion.
  module PendingDelete
    UPDATE = YjsFixtures.b64("${pendingDelete}")
  end

  # Fixture 11: a cross-client-origin gap. CONTENT is client 3's "abc"; DELTA is
  # client 1's insert BETWEEN client 3's characters, so its origins reference
  # client 3's blocks. On a doc lacking CONTENT, DELTA's per-client clock lower
  # bound passes but integration parks -- the readiness case a clock-only check
  # misses (update_ready? must say false).
  module CrossClientOrigin
    CONTENT = YjsFixtures.b64("${crossClientOrigin.content}")
    DELTA = YjsFixtures.b64("${crossClientOrigin.delta}")
  end

  # Fixture 12: 72 DISTINCT gappy updates (one per client 1000+i, each the second
  # delta of a two-insert doc whose first delta never ships). More than the
  # strike table's GAP_STRIKE_MAX_KEYS, all gappy on an empty store, all unique
  # bytes -- for proving eviction can't reset a tracked key's strikes.
  module GapFlood
    UPDATES = [
${gapFlood.map((u) => `      YjsFixtures.b64("${u}")`).join(",\n")}
    ].freeze
  end
end
`

process.stdout.write(fixtures)
