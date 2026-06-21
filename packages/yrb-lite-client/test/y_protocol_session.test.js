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

test("reliable:false sends fire-and-forget (no id, nothing pending)", () => {
  const { doc, eng, sent } = engine({ reliable: false });
  eng.onConnect();
  doc.getText("t").insert(0, "hi");
  assert.equal(sent.at(-1).id, undefined);
  assert.equal(eng.hasPending, false);
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
  // reliable:false so updates flow immediately with no server to ack them.
  const docA = new Y.Doc();
  const docB = new Y.Doc();
  let a, b;
  const relay = (target) => (frame) => {
    const reply = target.receive(frame);
    // reply (e.g. SyncStep2) goes back to the sender's peer as well
    return reply;
  };
  a = new YProtocolSession(docA, {
    reliable: false,
    send: (frame) => {
      const reply = b.receive(frame);
      if (reply) a.receive(reply);
    },
  });
  b = new YProtocolSession(docB, {
    reliable: false,
    send: (frame) => {
      const reply = a.receive(frame);
      if (reply) b.receive(reply);
    },
  });
  void relay;

  a.onConnect();
  b.onConnect();
  docA.getText("t").insert(0, "from A ");
  docB.getText("t").insert(0, "from B ");

  assert.equal(docA.getText("t").toString(), docB.getText("t").toString(), "docs converge byte-for-byte");
  assert.ok(docA.getText("t").toString().includes("from A"));
  assert.ok(docA.getText("t").toString().includes("from B"));
});

test("awareness frames are flagged { awareness: true } on the send callback; doc frames are not", () => {
  const doc = new Y.Doc();
  const awA = new Awareness(doc);
  const sends = []; // [{ type, awareness }]
  const eng = new YProtocolSession(doc, {
    awareness: awA,
    ...noTimers,
    send: (frame, _id, opts) => sends.push({ type: frameType(frame), awareness: !!(opts && opts.awareness) }),
  });
  eng.onConnect();
  doc.getText("t").insert(0, "hi"); // document update
  awA.setLocalStateField("user", "alice"); // presence

  const sync = sends.filter((s) => s.type === MSG.Sync);
  const awareness = sends.filter((s) => s.type === MSG.Awareness);
  assert.ok(sync.length >= 1 && sync.every((s) => s.awareness === false), "Sync frames are NOT flagged awareness");
  assert.ok(awareness.length >= 1 && awareness.every((s) => s.awareness === true), "Awareness frames ARE flagged");

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
