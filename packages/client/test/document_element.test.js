import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { MessageType, toBase64 } from "../dist/index.js";
import { YrbyDocumentElement } from "../dist/document_element.js";

// The element runs here without a DOM: the module's base class falls back to
// a plain class in Node, so tests drive the lifecycle callbacks directly and
// stub the two DOM methods the element touches (attributes, events).
function fakeConsumer() {
  const calls = { send: [], created: [] };
  let sub = null;
  const consumer = {
    calls,
    deliverConnected: () => sub.connected(),
    deliverReceived: (msg) => sub.received(msg),
    deliverRejected: () => sub.rejected(),
    subscriptions: {
      create(params, mixin) {
        calls.created.push(params);
        sub = {
          identifier: JSON.stringify(params),
          send: (data) => calls.send.push(data),
          unsubscribe: () => {
            calls.removed = (calls.removed || 0) + 1;
          },
          ...mixin,
        };
        return sub;
      },
    },
  };
  return consumer;
}

function syncStep2Envelope(peerDoc) {
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MessageType.Sync);
  encoding.writeVarUint(e, 1); // messageYjsSyncStep2
  encoding.writeVarUint8Array(e, Y.encodeStateAsUpdate(peerDoc));
  return { update: toBase64(encoding.toUint8Array(e)) };
}

function element(t, attributes, consumer) {
  const el = new YrbyDocumentElement();
  el.getAttribute = (name) => attributes[name] ?? null;
  el.setAttribute = (name, value) => { attributes[name] = value; };
  el.removeAttribute = (name) => { delete attributes[name]; };
  el.events = [];
  el.dispatchEvent = (event) => el.events.push(event);
  YrbyDocumentElement.consumer = consumer;
  t.after(() => {
    YrbyDocumentElement.consumer = undefined;
    el.destroy();
    el.doc.destroy();
  });
  return el;
}

test("connectedCallback subscribes with the element's grant and channel", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "signed-token", name: "body" }, consumer);

  await el.connectedCallback();

  assert.equal(consumer.calls.created.length, 1);
  assert.deepEqual(consumer.calls.created[0], {
    channel: "Y::DocumentChannel",
    grant: "signed-token",
    name: "body",
  });
  assert.ok(el.doc instanceof Y.Doc, "the element owns a doc");
  assert.ok(el.provider, "and the provider that syncs it");
});

test("a channel attribute overrides the default", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body", channel: "CustomChannel" }, consumer);

  await el.connectedCallback();

  assert.equal(consumer.calls.created[0].channel, "CustomChannel");
});

test("yrby:synced fires after the first catch-up, with the doc in reach", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);

  await el.connectedCallback();
  consumer.deliverConnected();
  consumer.deliverReceived(syncStep2Envelope(new Y.Doc()));
  await el.whenSynced;
  await new Promise((resolve) => setTimeout(resolve, 0)); // let the .then dispatch run

  assert.equal(el.events.length, 1);
  assert.equal(el.events[0].type, "yrby:synced");
  assert.equal(el.events[0].detail.doc, el.doc);
});

test("disconnect and reinsert reuse the same doc and provider", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);

  await el.connectedCallback();
  const { doc, provider } = el;
  el.disconnectedCallback();
  await el.connectedCallback();

  assert.equal(el.doc, doc, "a DOM move must not reset the document");
  assert.equal(el.provider, provider);
});

test("whenSynced waits for async startup AND the server catch-up", async (t) => {
  const consumer = fakeConsumer();
  let provide;
  const el = element(t, { grant: "g", name: "body" }, new Promise(r => { provide = r; }));
  const ready = el.whenSynced;
  let resolved = false;
  ready.then(() => { resolved = true; });
  const connecting = el.connectedCallback();
  await Promise.resolve();
  assert.equal(resolved, false);
  assert.equal(el.provider, undefined);
  provide(consumer);
  await connecting;
  assert.equal(el.whenSynced, ready);
  assert.equal(resolved, false);
  consumer.deliverConnected();
  const peer = new Y.Doc();
  peer.getText("content").insert(0, "server state");
  consumer.deliverReceived(syncStep2Envelope(peer));
  await ready;
  assert.equal(el.doc.getText("content").toString(), "server state");
  peer.destroy();
});

test("a removed element cannot connect after its consumer resolves", async (t) => {
  const consumer = fakeConsumer();
  let provide;
  const el = element(t, { grant: "g", name: "body" }, new Promise(r => { provide = r; }));
  const connecting = el.connectedCallback();
  el.disconnectedCallback();
  provide(consumer);
  await connecting;
  assert.equal(consumer.calls.created.length, 0);
  assert.equal(el.provider, undefined);
});

test("reinsert during initialization creates only the current subscription", async (t) => {
  const consumer = fakeConsumer();
  let provide;
  const el = element(t, { grant: "g", name: "body" }, new Promise(r => { provide = r; }));
  const old = el.connectedCallback();
  el.disconnectedCallback();
  const current = el.connectedCallback();
  provide(consumer);
  await Promise.all([old, current]);
  assert.equal(consumer.calls.created.length, 1);
});

test("async initialization failure emits an error and can be retried", async (t) => {
  const consumer = fakeConsumer();
  const error = new Error("consumer unavailable");
  const el = element(t, { grant: "g", name: "body" }, Promise.reject(error));
  await el.connectedCallback();
  assert.equal(el.events[0].type, "yrby:error");
  assert.equal(el.events[0].detail.error, error);
  assert.equal(el.provider, undefined);
  YrbyDocumentElement.consumer = consumer;
  await el.connectedCallback();
  assert.equal(consumer.calls.created.length, 1);
});

test("a stale initialization rejection cannot destroy a newer connection", async (t) => {
  const consumer = fakeConsumer();
  let rejectOld;
  const el = element(t, { grant: "g", name: "body" }, new Promise((_, reject) => { rejectOld = reject; }));
  const old = el.connectedCallback();
  el.disconnectedCallback();
  YrbyDocumentElement.consumer = consumer;
  await el.connectedCallback();
  const provider = el.provider;
  rejectOld(new Error("stale failure"));
  await old;
  assert.equal(el.provider, provider);
  assert.equal(provider.status, "connecting");
  assert.equal(el.events.length, 0);
});

test("destroy is idempotent and saved edits replay on reuse", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);
  await el.connectedCallback();
  el.doc.getText("content").insert(0, "saved edit");
  el.destroy();
  el.destroy();
  await el.connectedCallback();
  assert.equal(el.doc.getText("content").toString(), "saved edit");
  assert.equal(el.provider.hasPending, true);
});

test("a same-turn move does not unsubscribe or clear presence", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);
  await el.connectedCallback();
  el.provider.awareness.setLocalState({ user: { name: "Alice" } });
  el.disconnectedCallback();
  await el.connectedCallback();
  assert.equal(consumer.calls.removed ?? 0, 0);
  assert.equal(consumer.calls.created.length, 1);
  assert.deepEqual(el.provider.awareness.getLocalState(), { user: { name: "Alice" } });
});

test("delayed reinsertion restores presence while reusing the doc and provider", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);
  await el.connectedCallback();
  const provider = el.provider;
  provider.awareness.setLocalState({ user: { name: "Alice" } });
  el.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  assert.equal(provider.awareness.getLocalState(), null);
  await el.connectedCallback();
  assert.equal(el.provider, provider);
  assert.deepEqual(provider.awareness.getLocalState(), { user: { name: "Alice" } });
});

test("a cloned Turbo snapshot replays pending content until acked, and releases the old provider", async (t) => {
  const consumer = fakeConsumer();
  const attrs = { grant: "g", name: "body" };
  const original = element(t, attrs, consumer);
  const document = new EventTarget();
  original.ownerDocument = document;
  await original.connectedCallback();
  consumer.deliverConnected();
  original.doc.getText("content").insert(0, "unsent edit");
  assert.equal(original.provider.hasPending, true);
  const oldDoc = original.doc;
  const oldProvider = original.provider;
  document.dispatchEvent(new Event("turbo:before-cache"));
  const clonedAttrs = { ...attrs };
  original.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  assert.equal(original.provider, undefined);
  assert.equal(oldDoc.isDestroyed, false, "unacknowledged delivery still owns the original document");
  const pendingFrame = consumer.calls.send.find(m => m.id !== undefined);
  consumer.deliverReceived({ ack: pendingFrame.id });
  await Promise.resolve();
  assert.equal(oldDoc.isDestroyed, true);
  assert.equal(oldProvider.awareness.getLocalState(), null);

  const restoredConsumer = fakeConsumer();
  const restored = element(t, clonedAttrs, restoredConsumer);
  await restored.connectedCallback();
  restoredConsumer.deliverConnected();
  assert.equal(restored.doc.getText("content").toString(), "unsent edit");
  assert.equal(restored.provider.hasPending, true);
  const update = restoredConsumer.calls.send.find(m => m.id !== undefined);
  assert.ok(update, "restored bytes go through ack tracking");
  restoredConsumer.deliverReceived({ ack: update.id });
  assert.equal(restored.provider.hasPending, false);
});

test("cached state never crosses a changed grant, name or channel", async (t) => {
  const attrs = { grant: "g", name: "body" };
  const original = element(t, attrs, fakeConsumer());
  original.doc.getText("content").insert(0, "private state");
  original.destroy();
  for (const changed of [{ grant: "other" }, { name: "notes" }, { channel: "OtherChannel" }]) {
    const restored = element(t, { ...attrs, ...changed }, fakeConsumer());
    await restored.connectedCallback();
    assert.equal(restored.doc.getText("content").toString(), "");
    assert.equal(restored.provider.hasPending, false);
  }
});

test("snapshot restore queues only the small pending tail, not the saved document", async (t) => {
  const consumer = fakeConsumer();
  const attrs = { grant: "g", name: "body" };
  const original = element(t, attrs, consumer);
  await original.connectedCallback();
  const server = new Y.Doc();
  server.getText("content").insert(0, "x".repeat(100_000));
  original.provider.applyRemoteUpdate(Y.encodeStateAsUpdate(server));
  original.doc.getText("content").insert(100_000, "tail");
  original.destroy();
  const restoredConsumer = fakeConsumer();
  const restored = element(t, { ...attrs }, restoredConsumer);
  await restored.connectedCallback();
  restoredConsumer.deliverConnected();
  assert.equal(restored.doc.getText("content").length, 100_004);
  const frame = restoredConsumer.calls.send.find(m => m.id !== undefined);
  assert.ok(frame.update.length < 200, "only the small local tail goes on the wire");
  restoredConsumer.deliverReceived({ ack: frame.id });
  assert.equal(restored.provider.hasPending, false);
  restored.destroy();
  const clean = element(t, {
    grant: "g", name: "body", "data-yrby-snapshot": restored.getAttribute("data-yrby-snapshot")
  }, fakeConsumer());
  await clean.connectedCallback();
  assert.equal(clean.doc.getText("content").length, 100_004);
  assert.equal(clean.provider.hasPending, false, "acknowledged content is not requeued");
  server.destroy();
});

for (const changed of [{ grant: "other" }, { name: "notes" }, { channel: "OtherChannel" }]) {
  test(`retarget before caching never relabels the document: ${Object.keys(changed)[0]}`, async (t) => {
    const attrs = { grant: "g", name: "body" };
    const original = element(t, attrs, fakeConsumer());
    await original.connectedCallback();
    original.doc.getText("content").insert(0, "private pending edit");
    Object.assign(attrs, changed);
    const [key, value] = Object.entries(changed)[0];
    original.attributeChangedCallback(key, null, value);
    assert.equal(original.provider.status, "disconnected");
    assert.equal(original.provider.hasPending, true, "failed retarget keeps the original edit");
    assert.equal(original.events.at(-1).type, "yrby:error");
    original.destroy();
    assert.equal(JSON.parse(attrs["data-yrby-snapshot"]).identity, JSON.stringify(["Y::DocumentChannel", "g", "body"]));
    const restored = element(t, { ...attrs }, fakeConsumer());
    await restored.connectedCallback();
    assert.equal(restored.doc.getText("content").toString(), "");
    assert.equal(restored.provider.hasPending, false);
    const originalIdentity = element(t, { ...attrs, grant: "g", name: "body", channel: null }, fakeConsumer());
    await originalIdentity.connectedCallback();
    assert.equal(originalIdentity.doc.getText("content").toString(), "private pending edit");
    assert.equal(originalIdentity.provider.hasPending, true);
  });
}

test("retarget while the consumer is loading cannot subscribe with the old document", async (t) => {
  let provide;
  const attrs = { grant: "g", name: "body" };
  const consumer = fakeConsumer();
  const el = element(t, attrs, new Promise(resolve => { provide = resolve; }));
  const starting = el.connectedCallback();
  el.doc.getText("content").insert(0, "private before startup");
  attrs.grant = "other";
  el.attributeChangedCallback("grant", "g", "other");
  provide(consumer);
  await starting;
  assert.equal(consumer.calls.created.length, 0);
  el.destroy();
  assert.equal(JSON.parse(attrs["data-yrby-snapshot"]).identity, JSON.stringify(["Y::DocumentChannel", "g", "body"]));
});

test("a disconnected retarget fails closed and reverting reconnects the original provider", async (t) => {
  const attrs = { grant: "g", name: "body" };
  const el = element(t, attrs, fakeConsumer());
  await el.connectedCallback();
  const { provider } = el;
  el.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  attrs.grant = "other";
  await el.connectedCallback();
  assert.equal(provider.status, "disconnected");
  attrs.grant = "g";
  await el.connectedCallback();
  assert.equal(el.provider, provider);
  assert.equal(provider.status, "connecting");
});

test("Turbo preview cannot connect or resolve readiness and releases its document", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);
  el.ownerDocument = new EventTarget();
  el.ownerDocument.documentElement = { hasAttribute: () => true };
  let ready = false;
  el.whenSynced.then(() => { ready = true; });
  await el.connectedCallback();
  const doc = el.doc;
  assert.equal(el.inert, true);
  assert.equal(consumer.calls.created.length, 0);
  assert.equal(ready, false);
  el.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  assert.equal(doc.isDestroyed, true);
  assert.equal(el.provider, undefined);
});

test("navigation finishes pending delivery under the original grant before releasing it", async (t) => {
  const document = new EventTarget();
  const attrs = { grant: "original-grant", name: "body" };
  const consumer = fakeConsumer();
  const original = element(t, attrs, consumer);
  original.ownerDocument = document;
  await original.connectedCallback();
  consumer.deliverConnected();
  original.doc.getText("content").insert(0, "unsent before navigation");
  const { doc, provider } = original;
  document.dispatchEvent(new Event("turbo:before-cache"));
  original.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  assert.equal(original.provider, undefined);
  assert.equal(doc.isDestroyed, false);
  assert.equal(provider.awareness.getLocalState(), null);
  const fresh = element(t, { grant: "fresh-grant", name: "body" }, fakeConsumer());
  fresh.ownerDocument = document;
  await fresh.connectedCallback();
  assert.equal(fresh.provider.hasPending, false, "old tail is never reauthorized with a fresh grant");
  const frame = consumer.calls.send.find(m => m.id !== undefined);
  assert.equal(consumer.calls.created[0].grant, "original-grant");
  consumer.deliverReceived({ ack: frame.id });
  await Promise.resolve();
  assert.equal(doc.isDestroyed, true);
  assert.equal(provider.status, "disconnected");
});

test("a retained preview initializes when Turbo promotes it to the live page", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "g", name: "body" }, consumer);
  const document = el.ownerDocument = new EventTarget();
  let preview = true;
  document.documentElement = { hasAttribute: () => preview };
  el.inert = false;
  await el.connectedCallback();
  preview = false;
  document.dispatchEvent(new Event("turbo:render"));
  await Promise.resolve();
  assert.equal(consumer.calls.created.length, 1);
  assert.equal(el.inert, false);
  assert.ok(el.provider);
});


test("a rejected outgoing subscription releases resources while retaining its snapshot", async (t) => {
  const consumer = fakeConsumer();
  const el = element(t, { grant: "expired", name: "body" }, consumer);
  el.ownerDocument = new EventTarget();
  await el.connectedCallback();
  el.doc.getText("content").insert(0, "recoverable edit");
  const { doc, provider } = el;
  el.ownerDocument.dispatchEvent(new Event("turbo:before-cache"));
  el.disconnectedCallback();
  await new Promise(r => queueMicrotask(r));
  consumer.deliverRejected();
  assert.equal(doc.isDestroyed, true);
  assert.equal(provider.status, "disconnected");
  assert.ok(JSON.parse(el.getAttribute("data-yrby-snapshot")).pending);
});
