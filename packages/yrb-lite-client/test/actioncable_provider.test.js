import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { Awareness } from "y-protocols/awareness";
import { ActionCableProvider, MessageType, fromBase64, toBase64 } from "../dist/index.js";

// A fake ActionCable/AnyCable consumer. `withWhisper` toggles AnyCable's
// client-to-client whisper method so we can test both routing paths.
function fakeConsumer({ withWhisper } = { withWhisper: false }) {
  const calls = { send: [], whisper: [], removed: 0 };
  let sub = null;
  const consumer = {
    calls,
    deliverConnected: () => sub.connected(),
    deliverDisconnected: () => sub.disconnected(),
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
      remove: () => {
        calls.removed += 1;
      },
    },
  };
  return consumer;
}

const frameTypeOf = (b64) => fromBase64(b64)[0];

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

test("status walks connecting -> connected -> synced -> disconnected", (t) => {
  const doc = new Y.Doc();
  const c = fakeConsumer();
  const p = makeProvider(t, doc, c, { id: "s1" });
  const seen = [];
  p.on("status", ({ status }) => seen.push(status));

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

test("off() removes a status listener", (t) => {
  const c = fakeConsumer();
  const p = makeProvider(t, new Y.Doc(), c, { id: "s3" });
  const seen = [];
  const listener = ({ status }) => seen.push(status);
  p.on("status", listener);
  p.connect();
  p.off("status", listener);
  c.deliverConnected();
  assert.deepEqual(seen, ["connecting"], "no events after off()");
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
    .filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  assert.ok(removalFrames.length >= 1, "a final awareness frame went out on disconnect");
  assert.equal(p.awareness.getLocalState(), null, "local presence cleared");

  // The actual unsubscribe is deferred one microtask so the removal flushes first.
  assert.equal(c.calls.removed, 0, "unsubscribe is deferred, not synchronous");
  await Promise.resolve();
  assert.equal(c.calls.removed, 1, "unsubscribe runs after the microtask");
});

test("destroy() tears down the Awareness it created, but not a caller-supplied one", () => {
  // owns: default Awareness -> destroyed on destroy()
  const owned = new ActionCableProvider(new Y.Doc(), fakeConsumer(), "DocumentChannel", { id: "o1" });
  let ownedDestroyed = 0;
  const origDestroy = owned.awareness.destroy.bind(owned.awareness);
  owned.awareness.destroy = () => {
    ownedDestroyed += 1;
    origDestroy();
  };
  owned.destroy();
  assert.equal(ownedDestroyed, 1, "a provider-created Awareness is destroyed");

  // borrowed: caller-supplied Awareness -> left alone
  const doc = new Y.Doc();
  const mine = new Awareness(doc);
  let mineDestroyed = 0;
  const origMine = mine.destroy.bind(mine);
  mine.destroy = () => {
    mineDestroyed += 1;
    origMine();
  };
  const borrowed = new ActionCableProvider(doc, fakeConsumer(), "DocumentChannel", { id: "o2" }, { awareness: mine });
  borrowed.destroy();
  assert.equal(mineDestroyed, 0, "a caller-supplied Awareness is left for the caller to own");
  mine.destroy(); // cleanup the reaper interval
});

test("awareness: null disables it; undefined creates an owned one", (t) => {
  const c = fakeConsumer({ withWhisper: true });
  const disabled = new ActionCableProvider(new Y.Doc(), c, "DocumentChannel", { id: "a1" }, { awareness: null });
  assert.equal(disabled.awareness, null, "null disables awareness");
  disabled.connect();
  c.deliverConnected();
  disabled.disconnect(); // no presence removal possible
  const anyAwareness = [...c.calls.send, ...c.calls.whisper].some(
    (m) => frameTypeOf(m.update) === MessageType.Awareness
  );
  assert.equal(anyAwareness, false, "no awareness traffic at all when disabled");
  disabled.destroy(); // must not throw on a null awareness

  const owned = makeProvider(t, new Y.Doc(), fakeConsumer(), { id: "a2" });
  assert.ok(owned.awareness instanceof Awareness, "undefined creates an owned Awareness");
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
    .filter((m) => frameTypeOf(m.update) === MessageType.Awareness);
  assert.ok(removal.length >= 1, "pagehide sent a presence removal");

  p.disconnect();
  assert.ok(!handlers.has("pagehide"), "disconnect() unregistered the pagehide handler");
});
