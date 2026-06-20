import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import { Awareness } from "y-protocols/awareness";
import { ActionCableProvider, MessageType, fromBase64 } from "../dist/index.js";

// A fake ActionCable/AnyCable consumer. `withWhisper` toggles AnyCable's
// client-to-client whisper method so we can test both routing paths.
function fakeConsumer({ withWhisper } = { withWhisper: false }) {
  const calls = { send: [], whisper: [] };
  let sub = null;
  const consumer = {
    calls,
    deliverConnected: () => sub.connected(),
    deliverReceived: (msg) => sub.received(msg),
    subscriptions: {
      create(params, mixin) {
        sub = {
          identifier: JSON.stringify(params),
          send: (data) => calls.send.push(data),
          unsubscribe: () => {},
          ...mixin,
        };
        if (withWhisper) sub.whisper = (data) => calls.whisper.push(data);
        return sub;
      },
      remove: () => {},
    },
  };
  return consumer;
}

const frameTypeOf = (b64) => fromBase64(b64)[0];

// Create a provider and register failure-proof cleanup (a fresh Awareness starts
// its own reaper interval, which would keep the event loop alive otherwise).
function makeProvider(t, doc, consumer, params, opts) {
  const p = new ActionCableProvider(doc, consumer, "DocumentChannel", params, opts);
  t.after(() => {
    p.destroy();
    p.awareness.destroy();
  });
  return p;
}

test("constructs with a default awareness and exposes synced/hasPending", (t) => {
  const p = makeProvider(t, new Y.Doc(), fakeConsumer(), { id: "r1" });
  assert.ok(p.awareness instanceof Awareness, "a default Awareness is created");
  assert.equal(p.synced, false);
  assert.equal(p.hasPending, false);
});

test("on connect: the SyncStep1 handshake goes via normal send, never whisper", (t) => {
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, new Y.Doc(), c, { id: "r2" });
  p.connect();
  c.deliverConnected();
  const sentSync = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Sync);
  const whisperedSync = c.calls.whisper.filter((m) => frameTypeOf(m.update) === MessageType.Sync);
  assert.ok(sentSync.length >= 1, "the SyncStep1 handshake was sent");
  assert.equal(whisperedSync.length, 0, "no Sync frame is ever whispered (only awareness is)");
});

test("AnyCable (whisper available): awareness is WHISPERED, document updates are SENT", (t) => {
  // Automatic -- no flag: a whisper-capable subscription gets presence whispered.
  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, doc, c, { id: "r3" });
  p.connect();
  c.deliverConnected();

  doc.getText("t").insert(0, "hello"); // a document update
  p.awareness.setLocalStateField("user", "alice"); // a presence change

  const docSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Sync);
  const awarenessSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  const awarenessWhispers = c.calls.whisper.filter((m) => frameTypeOf(m.update) === MessageType.Awareness);

  assert.ok(docSends.length >= 1, "the document update went through send");
  assert.equal(awarenessSends.length, 0, "no awareness frame went through send");
  assert.ok(awarenessWhispers.length >= 1, "the presence change was whispered automatically");
});

test("plain ActionCable (no whisper): awareness falls back to normal send", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: false });
  const p = makeProvider(t, doc, c, { id: "r4" });
  p.connect();
  c.deliverConnected();

  p.awareness.setLocalStateField("user", "bob");

  const awarenessSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  assert.equal(c.calls.whisper.length, 0, "no whisper method, so nothing whispered");
  assert.ok(awarenessSends.length >= 1, "presence still delivered, via normal send");
});

test("reliable doc updates carry an id; an ack drains the queue", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer();
  const p = makeProvider(t, doc, c, { id: "r5" });
  p.connect();
  c.deliverConnected();
  doc.getText("t").insert(0, "x");
  const docMsg = c.calls.send.find((m) => m.id !== undefined);
  assert.ok(docMsg, "a reliable doc update is tagged with an id");
  assert.equal(p.hasPending, true);
  c.deliverReceived({ ack: docMsg.id });
  assert.equal(p.hasPending, false, "the ack drained the pending queue");
});
