import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { writeSyncStep1, writeUpdate } from "y-protocols/sync";
import { Awareness, encodeAwarenessUpdate } from "y-protocols/awareness";
import { YProtocolSession, MessageType } from "../dist/y_protocol_session.js";

const MSG = MessageType;

// Read the leading message type off a frame without consuming it elsewhere.
const frameType = (frame) => frame[0];

// Fake timers keep the resend loop out of the real event loop so tests don't hang.
const noTimers = { setInterval: () => 0, clearInterval: () => {} };

function engine(opts = {}) {
  const doc = new Y.Doc();
  const sent = []; // [{ frame, id }]
  const eng = new YProtocolSession(doc, { send: (frame, id) => sent.push({ frame, id }), ...noTimers, ...opts });
  return { doc, eng, sent };
}

// Build a peer's SyncStep1 / Update frames with y-protocols directly.
function syncStep1Frame(doc) {
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Sync);
  writeSyncStep1(e, doc);
  return encoding.toUint8Array(e);
}
function updateFrame(update) {
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Sync);
  writeUpdate(e, update);
  return encoding.toUint8Array(e);
}

test("requires a doc and a send function", () => {
  assert.throws(() => new YProtocolSession(null, { send: () => {} }), /Y\.Doc/);
  assert.throws(() => new YProtocolSession(new Y.Doc(), {}), /send/);
});

test("onConnect emits a SyncStep1 handshake frame", () => {
  const { eng, sent } = engine();
  eng.onConnect();
  assert.equal(sent.length, 1);
  assert.equal(frameType(sent[0].frame), MSG.Sync, "handshake is a Sync message");
  assert.equal(sent[0].id, undefined, "handshake carries no reliable id");
});

test("a local edit is framed as a Sync update and tagged with a reliable id", () => {
  const { doc, eng, sent } = engine();
  eng.onConnect();
  const before = sent.length;
  doc.getText("t").insert(0, "hi");
  const frame = sent.at(-1);
  assert.equal(sent.length, before + 1);
  assert.equal(frameType(frame.frame), MSG.Sync);
  assert.equal(typeof frame.id, "number", "reliable update carries an id");
  assert.equal(eng.hasPending, true);
});

test("an ack drains the pending queue", () => {
  const { doc, eng, sent } = engine();
  eng.onConnect();
  doc.getText("t").insert(0, "hi");
  const { id } = sent.at(-1);
  eng.ack(id);
  assert.equal(eng.hasPending, false);
});

test("applyRemoteUpdate seeds the doc without re-sending it as a local edit", () => {
  const { doc, eng, sent } = engine();

  // A bootstrap payload (e.g. initial state loaded over HTTP) applied before connect.
  const source = new Y.Doc();
  source.getText("t").insert(0, "bootstrapped");
  eng.applyRemoteUpdate(Y.encodeStateAsUpdate(source));

  assert.equal(doc.getText("t").toString(), "bootstrapped", "the bootstrap state is applied locally");
  assert.equal(eng.hasPending, false, "bootstrap state is NOT queued for reliable delivery");
  assert.equal(sent.length, 0, "nothing is sent before connect");

  // On connect, only the SyncStep1 handshake goes out, never a reliable
  // { update, id } frame echoing the bootstrap state back to the server.
  eng.onConnect();
  assert.equal(sent.length, 1, "only the handshake was sent");
  assert.equal(frameType(sent[0].frame), MSG.Sync, "and it's the SyncStep1 handshake");
  assert.equal(sent[0].id, undefined, "the handshake carries no reliable id");
  assert.equal(sent.filter((s) => s.id !== undefined).length, 0, "no reliable document frame for bootstrap state");
});

test("receive(SyncStep1) replies with a SyncStep2; receive(Update) applies to the doc", () => {
  const { doc, eng } = engine();
  // A peer that already has content sends us its SyncStep1...
  const peer = new Y.Doc();
  peer.getText("t").insert(0, "world");
  const reply = eng.receive(syncStep1Frame(peer));
  assert.ok(reply, "we answer a SyncStep1 with a reply (our SyncStep2)");
  assert.equal(frameType(reply), MSG.Sync);

  // ...and then its document update, which we apply.
  const update = Y.encodeStateAsUpdate(peer);
  eng.receive(updateFrame(update));
  assert.equal(doc.getText("t").toString(), "world", "the peer's update is applied locally");
});

test("synced flips true after a SyncStep2 arrives", () => {
  const { eng } = engine();
  assert.equal(eng.synced, false);
  const peer = new Y.Doc();
  peer.getText("t").insert(0, "x");
  // SyncStep1 -> reply is our step2; feeding the peer a step1 makes IT produce a
  // step2 for us. Simulate the server's SyncStep2 by replying to our step1.
  eng.onConnect(); // sends our SyncStep1 (ignored here)
  const serverReplyToOurStep1 = eng.receive(syncStep1Frame(peer)); // step1 in, step2 out is to peer
  // The server's SyncStep2 *to us*: build it from the peer answering our step vector.
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Sync);
  // a SyncStep2 is just an update payload under the step2 tag; reuse writeUpdate's
  // sibling via the peer's full state as the "diff".
  writeSyncStep2FromPeer(e, peer);
  eng.receive(encoding.toUint8Array(e));
  assert.equal(eng.synced, true, "receiving a SyncStep2 marks us synced");
  assert.ok(serverReplyToOurStep1);
});

test("two engines converge end-to-end through a relay", () => {
  const docA = new Y.Doc();
  const docB = new Y.Doc();
  let a, b;
  a = new YProtocolSession(docA, {
    ...noTimers,
    send: (frame, id) => {
      const reply = b.receive(frame);
      if (id !== undefined) a.ack(id);
      if (reply) a.receive(reply);
    },
  });
  b = new YProtocolSession(docB, {
    ...noTimers,
    send: (frame, id) => {
      const reply = a.receive(frame);
      if (id !== undefined) b.ack(id);
      if (reply) b.receive(reply);
    },
  });

  a.onConnect();
  b.onConnect();
  docA.getText("t").insert(0, "from A ");
  docB.getText("t").insert(0, "from B ");

  assert.equal(docA.getText("t").toString(), docB.getText("t").toString(), "docs converge byte-for-byte");
  assert.ok(docA.getText("t").toString().includes("from A"));
  assert.ok(docA.getText("t").toString().includes("from B"));
  a.destroy();
  b.destroy();
});

test("presence frames as Awareness, doc updates as Sync (the first byte identifies them)", () => {
  const doc = new Y.Doc();
  const awA = new Awareness(doc);
  const types = []; // frame[0] of each outgoing frame
  const eng = new YProtocolSession(doc, {
    awareness: awA,
    ...noTimers,
    send: (frame) => types.push(frameType(frame)),
  });
  eng.onConnect();
  doc.getText("t").insert(0, "hi"); // document update
  awA.setLocalStateField("user", "alice"); // presence

  assert.ok(types.includes(MSG.Sync), "a document update frames as Sync");
  assert.ok(types.includes(MSG.Awareness), "a presence change frames as Awareness");

  eng.destroy();
  awA.destroy();
});

test("awareness: a local presence change is framed; an incoming one is applied", () => {
  const docA = new Y.Doc();
  const awA = new Awareness(docA);
  const sentA = [];
  const engA = new YProtocolSession(docA, { awareness: awA, send: (frame, id) => sentA.push({ frame, id }) });

  awA.setLocalStateField("user", "alice");
  const awarenessFrame = sentA.find((s) => frameType(s.frame) === MSG.Awareness);
  assert.ok(awarenessFrame, "a presence change is sent as an Awareness frame");
  assert.equal(awarenessFrame.id, undefined, "presence is fire-and-forget");

  // Apply alice's presence into a second engine's awareness.
  const docB = new Y.Doc();
  const awB = new Awareness(docB);
  const engB = new YProtocolSession(docB, { awareness: awB, send: () => {} });
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Awareness);
  encoding.writeVarUint8Array(e, encodeAwarenessUpdate(awA, [docA.clientID]));
  engB.receive(encoding.toUint8Array(e));
  assert.equal(awB.getStates().get(docA.clientID)?.user, "alice", "remote presence is applied");

  engA.destroy();
  engB.destroy();
  awA.destroy(); // y-protocols Awareness starts its own reaper interval
  awB.destroy();
});

// A SyncStep2 frame carrying the peer's full state (server -> us "you're caught up").
function writeSyncStep2FromPeer(encoder, peer) {
  // 1 == messageYjsSyncStep2; payload is the state-as-update diff.
  encoding.writeVarUint(encoder, 1);
  encoding.writeVarUint8Array(encoder, Y.encodeStateAsUpdate(peer));
}

test("receive: a malformed frame is dropped, not thrown, and reports via onError", () => {
  const errors = [];
  const doc = new Y.Doc();
  const eng = new YProtocolSession(doc, {
    ...noTimers,
    send: () => {},
    onError: (err, context) => errors.push({ err, context }),
  });

  // A Sync frame whose body is garbage (claims more bytes than it carries).
  const bad = Uint8Array.from([MSG.Sync, 0xff, 0xff, 0xff, 0xff]);
  let reply;
  assert.doesNotThrow(() => {
    reply = eng.receive(bad);
  }, "a malformed frame must not throw into the transport callback");
  assert.equal(reply, null, "nothing to send back for a dropped frame");
  assert.equal(errors.length, 1, "onError fired once");
  assert.equal(errors[0].context, "receive", "context names where it failed");

  // The session is still live: a valid frame afterwards still works.
  assert.doesNotThrow(() => eng.receive(syncStep1Frame(new Y.Doc())));
  eng.destroy();
});

test("receive: an unknown message type is ignored without error", () => {
  const errors = [];
  const { eng } = engine({ onError: (err, context) => errors.push({ err, context }) });
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, 99); // not a known MessageType
  encoding.writeVarUint8Array(e, Uint8Array.from([1, 2, 3]));
  const reply = eng.receive(encoding.toUint8Array(e));
  assert.equal(reply, null, "unknown type yields no reply");
  assert.equal(errors.length, 0, "unknown type is not an error, just ignored");
  eng.destroy();
});

test("receive: trailing bytes after a complete message are rejected via onError", () => {
  const errors = [];
  const doc = new Y.Doc();
  const eng = new YProtocolSession(doc, { ...noTimers, send: () => {}, onError: (_e, c) => errors.push(c) });
  const good = syncStep1Frame(new Y.Doc());
  const padded = new Uint8Array(good.length + 1);
  padded.set(good, 0);
  padded[good.length] = 0xff; // one extra garbage byte
  const reply = eng.receive(padded);
  assert.equal(reply, null, "a frame with trailing bytes yields no reply");
  assert.ok(errors.includes("receive"), "trailing bytes reported via onError");
  eng.destroy();
});

test("receive: a padded sync update is rejected before mutating the doc", () => {
  const errors = [];
  const { doc, eng } = engine({ onError: (_e, c) => errors.push(c) });
  const peer = new Y.Doc();
  peer.getText("t").insert(0, "should not apply");
  const good = updateFrame(Y.encodeStateAsUpdate(peer));
  const padded = new Uint8Array(good.length + 1);
  padded.set(good, 0);
  padded[good.length] = 0xff;

  const reply = eng.receive(padded);

  assert.equal(reply, null, "malformed update yields no reply");
  assert.equal(doc.getText("t").toString(), "", "the valid prefix was not applied");
  assert.ok(errors.includes("receive"), "trailing bytes reported via onError");
  eng.destroy();
});

test("receive: a padded awareness update is rejected before mutating awareness", () => {
  const errors = [];
  const docA = new Y.Doc();
  const awA = new Awareness(docA);
  awA.setLocalStateField("user", "alice");
  const docB = new Y.Doc();
  const awB = new Awareness(docB);
  const engB = new YProtocolSession(docB, { awareness: awB, ...noTimers, send: () => {}, onError: (_e, c) => errors.push(c) });
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Awareness);
  encoding.writeVarUint8Array(e, encodeAwarenessUpdate(awA, [docA.clientID]));
  const good = encoding.toUint8Array(e);
  const padded = new Uint8Array(good.length + 1);
  padded.set(good, 0);
  padded[good.length] = 0xff;

  const reply = engB.receive(padded);

  assert.equal(reply, null, "malformed awareness yields no reply");
  assert.equal(awB.getStates().has(docA.clientID), false, "the valid prefix was not applied");
  assert.ok(errors.includes("receive"), "trailing bytes reported via onError");
  engB.destroy();
  awA.destroy();
  awB.destroy();
});

test("awareness: applying a remote update does NOT echo it back out (origin guard)", () => {
  // A produces a presence frame.
  const docA = new Y.Doc();
  const awA = new Awareness(docA);
  const engA = new YProtocolSession(docA, { awareness: awA, send: () => {} });
  awA.setLocalStateField("user", "alice");
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MSG.Awareness);
  encoding.writeVarUint8Array(e, encodeAwarenessUpdate(awA, [docA.clientID]));
  const aliceFrame = encoding.toUint8Array(e);

  // B applies it and must not re-send anything (no echo).
  const docB = new Y.Doc();
  const awB = new Awareness(docB);
  const sentB = [];
  const engB = new YProtocolSession(docB, { awareness: awB, send: (f) => sentB.push(f) });
  engB.receive(aliceFrame);
  assert.equal(awB.getStates().get(docA.clientID)?.user, "alice", "remote presence applied");
  assert.equal(
    sentB.filter((f) => frameType(f) === MSG.Awareness).length,
    0,
    "applied remote presence is NOT echoed back out"
  );

  engA.destroy();
  engB.destroy();
  awA.destroy();
  awB.destroy();
});

test("receive: a partially-malformed awareness payload mutates nothing (no half-applied entries)", () => {
  const doc = new Y.Doc();
  const awareness = new Awareness(doc);
  const errors = [];
  const session = new YProtocolSession(doc, {
    awareness,
    send: () => {},
    onError: (err) => errors.push(err),
  });

  // Craft an awareness payload with TWO entries: entry 0 valid, entry 1 carrying
  // invalid JSON. Without content validation, applyAwarenessUpdate would apply
  // entry 0, then throw on entry 1 with no event ever fired -- state mutated,
  // listeners never told.
  const inner = encoding.createEncoder();
  encoding.writeVarUint(inner, 2); // two entries
  encoding.writeVarUint(inner, 4242); // clientID
  encoding.writeVarUint(inner, 1); // clock
  encoding.writeVarString(inner, JSON.stringify({ user: "alice" })); // valid
  encoding.writeVarUint(inner, 4343);
  encoding.writeVarUint(inner, 1);
  encoding.writeVarString(inner, "{"); // invalid JSON
  const frame = encoding.createEncoder();
  encoding.writeVarUint(frame, MessageType.Awareness);
  encoding.writeVarUint8Array(frame, encoding.toUint8Array(inner));

  const reply = session.receive(encoding.toUint8Array(frame));

  assert.equal(reply, null);
  assert.equal(errors.length, 1, "the malformed payload is reported");
  assert.equal(awareness.getStates().has(4242), false, "the valid entry was NOT half-applied");
  session.destroy();
  awareness.destroy();
});

test("receive: an awareness payload with trailing bytes inside the blob is rejected", () => {
  const doc = new Y.Doc();
  const awareness = new Awareness(doc);
  const errors = [];
  const session = new YProtocolSession(doc, {
    awareness,
    send: () => {},
    onError: (err) => errors.push(err),
  });

  const inner = encoding.createEncoder();
  encoding.writeVarUint(inner, 1);
  encoding.writeVarUint(inner, 777);
  encoding.writeVarUint(inner, 1);
  encoding.writeVarString(inner, JSON.stringify({ user: "eve" }));
  const padded = new Uint8Array([...encoding.toUint8Array(inner), 0xde, 0xad]); // garbage inside the blob
  const frame = encoding.createEncoder();
  encoding.writeVarUint(frame, MessageType.Awareness);
  encoding.writeVarUint8Array(frame, padded);

  session.receive(encoding.toUint8Array(frame));

  assert.equal(errors.length, 1, "trailing bytes inside the awareness blob are rejected");
  assert.equal(awareness.getStates().has(777), false, "nothing was applied");
  session.destroy();
  awareness.destroy();
});
