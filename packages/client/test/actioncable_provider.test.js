import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { Awareness } from "y-protocols/awareness";
import { ActionCableProvider, MessageType, fromBase64, toBase64 } from "../dist/index.js";

// A fake ActionCable/AnyCable consumer. `withWhisper` exposes AnyCable's
// client-to-client whisper method so tests can verify awareness uses it without
// routing document updates through it.
function fakeConsumer({ withWhisper } = { withWhisper: false }) {
  const calls = { send: [], whisper: [], removed: 0 };
  let sub = null;
  const consumer = {
    calls,
    deliverConnected: () => sub.connected(),
    deliverDisconnected: () => sub.disconnected(),
    deliverRejected: () => sub.rejected(),
    deliverReceived: (msg) => sub.received(msg),
    // No `subscriptions.remove` -- mirrors @anycable/web (which has none). Teardown
    // goes through the subscription's own unsubscribe(), the universal path.
    subscriptions: {
      create(params, mixin) {
        sub = {
          identifier: JSON.stringify(params),
          send: (data) => calls.send.push(data),
          unsubscribe: () => {
            calls.removed += 1;
          },
          ...mixin,
        };
        if (withWhisper) sub.whisper = (data) => calls.whisper.push(data);
        return sub;
      },
    },
  };
  return consumer;
}

const frameTypeOf = (b64) => fromBase64(b64)[0];
const frameTypeOfMessage = (message) => frameTypeOf(message.awareness ?? message.update);

// Build the envelope a server sends to say "you're caught up": a Sync frame
// carrying SyncStep2 (message type 1) with the peer's full state.
function syncStep2Envelope(peerDoc) {
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MessageType.Sync);
  encoding.writeVarUint(e, 1); // messageYjsSyncStep2
  encoding.writeVarUint8Array(e, Y.encodeStateAsUpdate(peerDoc));
  return { update: toBase64(encoding.toUint8Array(e)) };
}

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
  const whisperedSync = c.calls.whisper.filter((m) => frameTypeOfMessage(m) === MessageType.Sync);
  assert.ok(sentSync.length >= 1, "the SyncStep1 handshake was sent");
  assert.equal(whisperedSync.length, 0, "no Sync frame is ever whispered");
});

test("AnyCable (whisper available): awareness is WHISPERED, document updates are SENT", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, doc, c, { id: "r3" });
  p.connect();
  c.deliverConnected();

  doc.getText("t").insert(0, "hello"); // a document update
  p.awareness.setLocalStateField("user", "alice"); // a presence change

  const docSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Sync);
  const awarenessSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  const awarenessWhispers = c.calls.whisper.filter((m) => frameTypeOf(m.awareness) === MessageType.Awareness);

  assert.ok(docSends.length >= 1, "the document update went through send");
  assert.equal(awarenessSends.length, 0, "the presence change did not go through send");
  assert.ok(awarenessWhispers.length >= 1, "the presence change was whispered");
  assert.ok(c.calls.whisper.every((m) => typeof m.awareness === "string"), "whispers use the awareness-only envelope");
});

test("plain ActionCable: awareness uses normal send", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: false });
  const p = makeProvider(t, doc, c, { id: "r4" });
  p.connect();
  c.deliverConnected();

  p.awareness.setLocalStateField("user", "bob");

  const awarenessSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  assert.equal(c.calls.whisper.length, 0, "nothing whispered");
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

test("applyRemoteUpdate seeds the doc without queuing a reliable frame on connect", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer();
  const p = makeProvider(t, doc, c, { id: "boot1" });

  // Seed initial state the way an app would from an HTTP-loaded snapshot, before
  // connecting. A bare Y.applyUpdate here would be re-broadcast as a pending edit.
  const source = new Y.Doc();
  source.getText("t").insert(0, "from HTTP");
  p.applyRemoteUpdate(Y.encodeStateAsUpdate(source));

  assert.equal(doc.getText("t").toString(), "from HTTP", "bootstrap state applied");
  assert.equal(p.hasPending, false, "bootstrap state is not pending delivery");

  p.connect();
  c.deliverConnected();

  const reliable = c.calls.send.filter((m) => m.id !== undefined);
  assert.equal(reliable.length, 0, "no reliable { update, id } frame echoing the bootstrap state");
  const syncSends = c.calls.send.filter((m) => frameTypeOf(m.update) === MessageType.Sync);
  assert.ok(syncSends.length >= 1, "the SyncStep1 handshake still went out");
});

test("status walks connecting -> connected -> synced -> disconnected", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer();
  const p = makeProvider(t, doc, c, { id: "s1" });
  const seen = [];
  p.onStatusChange(({ status }) => seen.push(status));

  assert.equal(p.status, "disconnected", "starts disconnected");
  p.connect();
  assert.equal(p.status, "connecting", "subscription created, transport not up");
  c.deliverConnected();
  assert.equal(p.status, "connected", "transport up, not yet synced (UI: syncing)");
  c.deliverReceived(syncStep2Envelope(new Y.Doc()));
  assert.equal(p.status, "synced", "a SyncStep2 flips us to synced");
  p.disconnect();
  assert.equal(p.status, "disconnected", "explicit disconnect -> disconnected");

  assert.deepEqual(seen, ["connecting", "connected", "synced", "disconnected"]);
});

test("a dropped transport (ActionCable will retry) shows as connecting, not disconnected", (t) => {
  const c = fakeConsumer();
  const p = makeProvider(t, new Y.Doc(), c, { id: "s2" });
  p.connect();
  c.deliverConnected();
  assert.equal(p.status, "connected");
  c.deliverDisconnected(); // transport blip; subscription still alive
  assert.equal(p.status, "connecting", "subscription still set -> retrying, not torn down");
});

test("the returned unsubscribe stops a status listener", (t) => {
  const c = fakeConsumer();
  const p = makeProvider(t, new Y.Doc(), c, { id: "s3" });
  const seen = [];
  const unsubscribe = p.onStatusChange(({ status }) => seen.push(status));
  p.connect();
  unsubscribe();
  c.deliverConnected();
  assert.deepEqual(seen, ["connecting"], "no events after unsubscribe");
});

test("disconnect() broadcasts a presence removal while the transport is still live", async (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, doc, c, { id: "d1" });
  p.connect();
  c.deliverConnected();
  p.awareness.setLocalStateField("user", "alice");
  const whispersBefore = c.calls.whisper.length;
  assert.notEqual(p.awareness.getLocalState(), null, "alice has presence");

  p.disconnect();

  const removalFrames = c.calls.whisper
    .slice(whispersBefore)
    .filter((m) => frameTypeOf(m.awareness) === MessageType.Awareness);
  assert.ok(removalFrames.length >= 1, "a final awareness frame went out on disconnect");
  assert.equal(p.awareness.getLocalState(), null, "local presence cleared");

  // The actual unsubscribe is deferred one microtask so the removal flushes first.
  assert.equal(c.calls.removed, 0, "unsubscribe is deferred, not synchronous");
  await Promise.resolve();
  assert.equal(c.calls.removed, 1, "unsubscribe runs after the microtask");
});

test("destroy() tears down the Awareness it created", () => {
  const owned = new ActionCableProvider(new Y.Doc(), fakeConsumer(), "DocumentChannel", { id: "o1" });
  let ownedDestroyed = 0;
  const origDestroy = owned.awareness.destroy.bind(owned.awareness);
  owned.awareness.destroy = () => {
    ownedDestroyed += 1;
    origDestroy();
  };
  owned.destroy();
  assert.equal(ownedDestroyed, 1, "a provider-created Awareness is destroyed");
});

test("the provider creates and owns an Awareness", (t) => {
  const owned = makeProvider(t, new Y.Doc(), fakeConsumer(), { id: "a2" });
  assert.ok(owned.awareness instanceof Awareness, "the provider owns a fresh Awareness");
});

test("a browser pagehide broadcasts a best-effort presence removal", (t) => {
  // Simulate a browser environment with a minimal window event target.
  const handlers = new Map();
  const fakeWindow = {
    addEventListener: (type, fn) => handlers.set(type, fn),
    removeEventListener: (type, fn) => {
      if (handlers.get(type) === fn) handlers.delete(type);
    },
  };
  const prev = globalThis.window;
  globalThis.window = fakeWindow;
  t.after(() => {
    if (prev === undefined) delete globalThis.window;
    else globalThis.window = prev;
  });

  const doc = new Y.Doc();
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, doc, c, { id: "u1" });
  p.connect();
  c.deliverConnected();
  p.awareness.setLocalStateField("user", "carol");
  assert.ok(handlers.has("pagehide"), "connect() registered a pagehide handler");

  const whispersBefore = c.calls.whisper.length;
  handlers.get("pagehide")(); // fire pagehide
  const removal = c.calls.whisper
    .slice(whispersBefore)
    .filter((m) => frameTypeOf(m.awareness) === MessageType.Awareness);
  assert.ok(removal.length >= 1, "pagehide sent a presence removal");

  p.disconnect();
  assert.ok(!handlers.has("pagehide"), "disconnect() unregistered the pagehide handler");
});

test("received awareness envelope rejects non-awareness frames", (t) => {
  const errors = [];
  const c = fakeConsumer({ withWhisper: true });
  const p = makeProvider(t, new Y.Doc(), c, { id: "aw1" }, { onError: (err, context) => errors.push({ err, context }) });
  p.connect();
  c.deliverConnected();

  const bad = syncStep2Envelope(new Y.Doc()).update;
  c.deliverReceived({ awareness: bad });

  assert.equal(errors.length, 1, "bad awareness envelope was reported");
  assert.equal(errors[0].context, "received");
  assert.match(String(errors[0].err?.message ?? errors[0].err), /non-awareness/);
});

test("a rejected subscription surfaces via onError and tears down (no infinite 'connecting')", (t) => {
  const c = fakeConsumer();
  const errors = [];
  const p = makeProvider(t, new Y.Doc(), c, { id: "rej" }, { onError: (err, context) => errors.push({ err, context }) });
  const statuses = [];
  p.onStatusChange(({ status }) => statuses.push(status));

  p.connect();
  c.deliverRejected();

  assert.equal(errors.length, 1, "rejection is reported");
  assert.equal(errors[0].context, "rejected");
  assert.equal(p.status, "disconnected", "provider tears down instead of hanging at 'connecting'");
  assert.deepEqual(statuses, ["connecting", "disconnected"]);
});

test("a throwing transport send is reported, not thrown into update handlers", (t) => {
  const c = fakeConsumer();
  const errors = [];
  const doc = new Y.Doc();
  const p = makeProvider(t, doc, c, { id: "boom" }, { onError: (err, context) => errors.push({ err, context }) });
  p.connect();
  c.deliverConnected();
  // Sabotage the transport AFTER connect so the handshake went out normally.
  const sub = c.subscriptions.create; // (fakeConsumer keeps `sub` internal; sabotage via calls)
  c.calls.send.length = 0;
  const brokenSend = new Error("socket gone");
  // Replace send on the live subscription through a received-side effect: easiest
  // is to monkey-patch through the consumer's stored sub via deliver* closure.
  // fakeConsumer exposes no direct handle, so patch through the provider's edit path:
  // make every push throw by redefining the calls array's push.
  c.calls.send.push = () => {
    throw brokenSend;
  };

  doc.getText("t").insert(0, "x"); // triggers a reliable send through the broken transport

  assert.ok(errors.some((e) => e.context === "send" && e.err === brokenSend), "send failure surfaced via onError");
  assert.ok(p.hasPending, "the edit stays queued for retransmit despite the failed send");
});

test("a promise-rejecting transport send surfaces via onError (no unhandled rejection)", async (t) => {
  const c = fakeConsumer();
  const errors = [];
  const doc = new Y.Doc();
  const p = makeProvider(t, doc, c, { id: "rejp" }, { onError: (err, context) => errors.push({ err, context }) });
  p.connect();
  c.deliverConnected();
  c.calls.send.length = 0;
  const rejection = new Error("async transport failure");
  c.calls.send.push = () => Promise.reject(rejection);
  // #send observes the transport's return value; fake it by returning from push
  // (the fake sub's send returns calls.send.push(...)'s result).

  doc.getText("t").insert(0, "y");
  await new Promise((resolve) => setTimeout(resolve, 0)); // let the rejection propagate

  assert.ok(errors.some((e) => e.context === "send" && e.err === rejection), "promise rejection observed via onError");
});
