import { test } from "node:test";
import assert from "node:assert/strict";
import { YrbyDocumentElement } from "../dist/document_element.js";
import { DocumentSessionStore } from "../dist/index.js";
import { disconnectTurbo } from "../dist/turbo_adapter.js";
import { fakeConsumer, sync, tick } from "./session_helpers.js";

function setup(t, attributes = { grant: "g", name: "body" }, consumer = fakeConsumer(), document = new EventTarget()) {
  const el = new YrbyDocumentElement();
  let connected = false;
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
  await tick();
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
  await tick();
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


test("activation cannot acquire a document before DOM connection or after removal", async t => {
  const { el, consumer, mount, remove } = setup(t);
  el.activate(); await tick();
  assert.equal(consumer.created.length, 0);
  assert.equal(el.doc, undefined);
  await mount();
  assert.equal(consumer.created.length, 1);
  remove(); await tick();
  el.activate(); await tick();
  assert.equal(consumer.created.length, 1);
  assert.equal(el.doc, undefined);
});

test("a consumer resolving just before removal cannot subscribe from a queued continuation", async t => {
  const consumer = fakeConsumer();
  let provide;
  const { el, mount, remove } = setup(t, undefined, new Promise(resolve => { provide = resolve; }));
  await mount();
  provide(consumer); // queues attach's continuation before deferred DOM cleanup
  remove();
  await tick();
  assert.equal(consumer.created.length, 0);
  assert.equal(el.doc, undefined);
});

test("sync completing just before removal cannot announce an abandoned editor", async t => {
  const { el, consumer, mount, remove } = setup(t);
  await mount();
  let ready = false;
  el.whenSynced.then(() => { ready = true; });
  sync(consumer.created[0]);
  remove();
  await tick();
  assert.equal(ready, false);
  assert.equal(el.events.length, 0);
  assert.equal(el.doc, undefined);
});

for (const field of ["grant", "name", "channel"]) {
  test(`retargeting ${field} during a same-turn DOM move preserves the original queue but replaces the binding`, async t => {
    const { el, consumer, mount, remove, change } = setup(t);
    await mount(); sync(consumer.created[0], "original"); await el.whenSynced;
    const session = el.session, signal = el.events[0].detail.signal;
    session.doc.getText("content").insert(0, "pending ");
    remove();
    change(field, "other");
    await mount();
    assert.equal(signal.aborted, true);
    assert.notEqual(el.session, session);
    assert.equal(el.session.descriptor[field], "other");
    assert.equal(session.hasPending, true);
    assert.equal(session.doc.getText("content").toString(), "pending original");
    assert.equal(el.doc.getText("content").toString(), "");
  });
}


test("canceled consumer readiness stays abandoned after a later successful mount", async t => {
  const consumer = fakeConsumer();
  let provide;
  const { el, mount, remove } = setup(t, undefined, new Promise(resolve => { provide = resolve; }));
  let abandonedReady = false;
  el.whenSynced.then(() => { abandonedReady = true; });
  await mount();
  provide(consumer);
  remove();
  await tick();
  await mount();
  sync(consumer.created.at(-1)); await el.whenSynced;
  assert.equal(abandonedReady, false);
  assert.equal(el.events.length, 1);
});

test("an inactive element preserves its initial readiness until its first lease", async t => {
  const { el, consumer, mount } = setup(t);
  const ready = el.whenSynced;
  el.activate(); el.deactivate(); await tick();
  assert.equal(el.whenSynced, ready);
  await mount(); sync(consumer.created[0]); await ready;
  assert.equal(el.events.length, 1);
});


test("a queued retarget cannot reactivate an element suspended for caching", async t => {
  const { el, consumer, mount, change } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  change("name", "other");
  el.deactivate();
  await tick();
  assert.equal(el.doc, undefined);
  assert.equal(el.inert, true);
  assert.equal(consumer.created.length, 1);
  el.activate(); await tick();
  assert.equal(consumer.created.at(-1).params.name, "other");
});

test("retargeting inside acquisition cannot install a lease for the previous descriptor", async t => {
  const { el, consumer, mount, change } = setup(t);
  const store = DocumentSessionStore.for(consumer);
  store.addEventListener("change", () => { change("name", "replacement"); }, { once: true });
  await mount();
  assert.equal(el.session.descriptor.name, "replacement");
  assert.equal(store.sessions.length, 1);
  assert.equal(store.sessions[0], el.session);
  sync(consumer.created.at(-1)); await el.whenSynced;
  assert.equal(el.events.length, 1);
  assert.equal(el.events[0].detail.session.descriptor.name, "replacement");
});

for (const action of ["deactivate", "discard"]) {
  test(`${action} inside acquisition cannot leave an abandoned lease installed`, async t => {
    const { el, consumer, mount } = setup(t);
    const store = DocumentSessionStore.for(consumer);
    let abandonedReady = false;
    el.whenSynced.then(() => { abandonedReady = true; });
    store.addEventListener("change", event => {
      if (action === "deactivate") el.deactivate();
      else event.detail.discard();
    }, { once: true });
    await mount();
    assert.equal(el.session, undefined);
    assert.equal(el.doc, undefined);
    assert.equal(el.inert, true);
    assert.equal(el.events.length, 0);
    assert.equal(store.sessions.length, 0);
    el.activate(); await tick();
    sync(consumer.created.at(-1)); await el.whenSynced;
    assert.equal(el.events.length, 1);
    assert.equal(abandonedReady, false);
  });
}

test("a failed consumer attempt cannot resolve its abandoned readiness on a later activation", async t => {
  let fail;
  const { el, mount } = setup(t, undefined, new Promise((_, reject) => { fail = reject; }));
  let abandonedReady = false;
  el.whenSynced.then(() => { abandonedReady = true; });
  await mount();
  const error = new Error("unavailable");
  fail(error); await tick();
  assert.equal(el.events[0].type, "yrby:error");
  assert.equal(el.events[0].detail.error, error);
  const consumer = fakeConsumer();
  YrbyDocumentElement.consumer = consumer;
  el.activate(); await tick();
  sync(consumer.created[0]); await el.whenSynced;
  assert.equal(el.events[1].type, "yrby:synced");
  assert.equal(abandonedReady, false);
});
