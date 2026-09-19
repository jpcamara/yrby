import { test } from "node:test";
import assert from "node:assert/strict";
import { YrbyDocumentElement } from "../dist/document_element.js";
import { DocumentSessionStore } from "../dist/index.js";
import { disconnectTurbo } from "../dist/turbo_adapter.js";
import { fakeConsumer, sync, tick } from "./session_helpers.js";

function setup(t, attributes = { grant: "g", name: "body" }, consumer = fakeConsumer(), document = new EventTarget()) {
  const el = new YrbyDocumentElement();
  let connected = true;
  el.ownerDocument = document;
  Object.defineProperty(el, "isConnected", { get: () => connected });
  el.getAttribute = name => attributes[name] ?? null;
  el.setAttribute = (name, value) => { attributes[name] = value; };
  el.removeAttribute = name => { delete attributes[name]; };
  el.events = [];
  el.dispatchEvent = event => { el.events.push(event); return true; };
  el.inert = false;
  YrbyDocumentElement.consumer = consumer;
  const mount = async () => { connected = true; el.connectedCallback(); await tick(); };
  const remove = () => { connected = false; el.disconnectedCallback(); };
  const change = (name, value) => { const old = attributes[name]; attributes[name] = value; el.attributeChangedCallback(name, old, value); };
  t.after(async () => {
    remove(); await tick(); disconnectTurbo(document);
    if (consumer.created) for (const session of DocumentSessionStore.for(consumer).sessions) session.discard();
    YrbyDocumentElement.consumer = undefined;
  });
  return { el, consumer, mount, remove, change, document };
}

test("readiness is available before async startup; no unowned document exists", async t => {
  const actual = fakeConsumer();
  let provide;
  const { el, mount } = setup(t, undefined, new Promise(resolve => { provide = resolve; }));
  const ready = el.whenSynced;
  let resolved = false;
  ready.then(() => { resolved = true; });
  await mount();
  assert.equal(el.doc, undefined);
  assert.equal(el.provider, undefined);
  provide(actual);
  await tick();
  assert.equal(resolved, false);
  assert.equal(el.inert, true);
  sync(actual.created[0], "saved");
  await ready;
  assert.equal(el.doc.getText("content").toString(), "saved");
  assert.equal(el.inert, false);
  assert.equal(el.events[0].detail.signal.aborted, false);
});

test("removed elements cannot subscribe after the consumer resolves", async t => {
  const consumer = fakeConsumer();
  let provide;
  const { el, mount, remove } = setup(t, undefined, new Promise(resolve => { provide = resolve; }));
  await mount(); remove(); provide(consumer); await tick();
  assert.equal(consumer.created.length, 0);
  assert.equal(el.doc, undefined);
});

test("same-turn DOM moves retain binding and document, clean delayed remounts reconstruct", async t => {
  const { el, consumer, mount, remove } = setup(t);
  await mount(); sync(consumer.created[0], "saved"); await el.whenSynced;
  const { doc, provider } = el, signal = el.events[0].detail.lease.signal;
  remove(); await mount();
  assert.equal(el.doc, doc);
  assert.equal(el.provider, provider);
  assert.equal(signal.aborted, false);
  assert.equal(el.events.length, 1);
  remove(); await tick();
  assert.equal(signal.aborted, true);
  assert.equal(doc.isDestroyed, true);
  await mount(); sync(consumer.created.at(-1), "saved"); await el.whenSynced;
  assert.notEqual(el.doc, doc);
  assert.equal(el.doc.getText("content").toString(), "saved");
});

for (const field of ["grant", "name", "channel"]) {
  test(`retargeting ${field} aborts the old binding and leaves its pending edits in the original session`, async t => {
    const { el, consumer, mount, change } = setup(t);
    await mount(); sync(consumer.created[0]); await el.whenSynced;
    const session = el.session, signal = el.events[0].detail.signal;
    el.doc.getText("content").insert(0, "private edit");
    change(field, "other");
    assert.equal(signal.aborted, true);
    assert.equal(el.doc, undefined);
    await tick();
    assert.notEqual(el.session, session);
    assert.equal(session.hasPending, true);
    assert.equal(session.descriptor[field], field === "channel" ? "Y::DocumentChannel" : field === "grant" ? "g" : "body");
    assert.equal(el.doc.getText("content").toString(), "");
    assert.equal(el.provider.hasPending, false);
  });
}

test("multiple attribute changes during startup acquire only the complete current tuple", async t => {
  const consumer = fakeConsumer();
  let provide;
  const { el, mount, change } = setup(t, undefined, new Promise(resolve => { provide = resolve; }));
  await mount(); change("grant", "other"); change("name", "notes"); provide(consumer); await tick();
  assert.equal(consumer.created.length, 1);
  assert.equal(consumer.created[0].params.grant, "other");
  assert.equal(consumer.created[0].params.name, "notes");
  el.destroy();
});

test("cached previews have no document or provider; promotion binds once", async t => {
  const document = new EventTarget();
  let preview = true;
  document.documentElement = { hasAttribute: () => preview };
  const { el, consumer, mount } = setup(t, undefined, undefined, document);
  await mount();
  assert.equal(el.inert, true);
  assert.equal(el.doc, undefined);
  assert.equal(consumer.created.length, 0);
  preview = false;
  document.dispatchEvent(new Event("turbo:render"));
  document.dispatchEvent(new Event("turbo:load"));
  await tick();
  sync(consumer.created[0]); await el.whenSynced;
  assert.equal(consumer.created.length, 1);
  assert.equal(el.events.length, 1);
});

test("before-cache releases bindings and a canceled navigation rebinds passive markup", { timeout: 5000 }, async t => {
  const { el, consumer, document, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const signal = el.events[0].detail.signal;
  const originalSubscription = consumer.created.at(-1);
  document.dispatchEvent(new Event("turbo:before-cache"));
  assert.equal(signal.aborted, true);
  assert.equal(el.doc, undefined);
  // Wait for the observable replacement, not elapsed time: a busy event loop
  // can run the old fixed delay before Turbo's deferred reconciliation finishes.
  const started = performance.now();
  while (consumer.created.at(-1) === originalSubscription && performance.now() - started < 2000) {
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.notEqual(consumer.created.at(-1), originalSubscription, "expected a replacement subscription");
  sync(consumer.created.at(-1)); await el.whenSynced;
  assert.equal(el.events.length, 2);
});

test("rejection aborts editor cleanup, reports the recoverable session, and stays inert", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session;
  const signal = el.events[0].detail.signal;
  signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "final"));
  consumer.created[0].handlers.rejected();
  assert.equal(el.inert, true);
  assert.equal(el.doc, undefined);
  assert.equal(session.hasPending, true);
  assert.equal(el.events.at(-1).type, "yrby:error");
  assert.equal(el.events.at(-1).detail.session, session);
});

test("a stale failed initialization cannot damage a newer lease", async t => {
  let reject;
  const consumer = fakeConsumer();
  const { el, mount, remove } = setup(t, undefined, new Promise((_, r) => { reject = r; }));
  await mount(); remove(); await tick();
  YrbyDocumentElement.consumer = consumer;
  await mount();
  const session = el.session;
  reject(new Error("old")); await tick();
  assert.equal(el.session, session);
  assert.equal(el.events.length, 0);
});


test("cached library inert state is cleared on readiness while application inert is preserved", async t => {
  for (const original of [false, true]) {
    const { el, consumer, mount } = setup(t, { grant: "g", name: "body", "data-yrby-inert": String(original) });
    el.inert = true; // clone of a suspended editor
    await mount(); sync(consumer.created[0]); await el.whenSynced;
    assert.equal(el.inert, original);
    assert.equal(el.getAttribute("data-yrby-inert"), null);
  }
});


test("old adapter cleanup cannot unregister a replacement adapter in the same document", async t => {
  const document = new EventTarget();
  const consumer = fakeConsumer();
  const old = setup(t, undefined, consumer, document);
  await old.mount();
  disconnectTurbo(document);
  const current = setup(t, undefined, consumer, document);
  await current.mount();
  const doc = current.el.doc;
  old.remove(); await tick();
  disconnectTurbo(document);
  assert.equal(current.el.doc, undefined);
  assert.equal(doc.isDestroyed, true);
});

test("the refresh attribute reaches the session and changing it does not rebind", async t => {
  const { el, consumer, mount, change } = setup(t, { grant: "g", name: "body", refresh: "/grant" });
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session, signal = el.events[0].detail.signal;
  assert.equal(session.descriptor.refresh, "/grant");
  change("refresh", "/other");
  await tick();
  assert.equal(signal.aborted, false);
  assert.equal(el.session, session);
});
