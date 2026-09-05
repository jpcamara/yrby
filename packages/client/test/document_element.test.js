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
  el.events = [];
  el.dispatchEvent = (event) => el.events.push(event);
  YrbyDocumentElement.consumer = consumer;
  t.after(() => {
    YrbyDocumentElement.consumer = undefined;
    el.provider?.destroy();
    el.provider?.awareness.destroy();
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

  assert.equal(el.doc, doc, "a Turbo restore must not reset the document");
  assert.equal(el.provider, provider);
});
