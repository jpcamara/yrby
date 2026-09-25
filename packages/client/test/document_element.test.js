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
  el.hasAttribute = name => name in attributes;
  el.events = [];
  el.dispatchEvent = event => { el.events.push(event); return true; };
  el.inert = false;
  YrbyDocumentElement.consumer = consumer;
  const mount = async () => { connected = true; el.connectedCallback(); await tick(); };
  const remove = () => { connected = false; el.disconnectedCallback(); };
  // Like a browser, only observed attributes reach the callback.
  const change = (name, value) => {
    const old = attributes[name] ?? null;
    attributes[name] = value;
    if (YrbyDocumentElement.observedAttributes.includes(name)) el.attributeChangedCallback(name, old, value);
  };
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

test("an editor's abort handler no longer sees the released document", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  let seen = "unset";
  el.events[0].detail.signal.addEventListener("abort", () => { seen = el.doc; });
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(seen, undefined);
});

test("reactivating an element whose session is still blocked reports it again and stays inert", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(el.events.at(-1).type, "yrby:error");
  el.activate(); await tick();
  assert.equal(el.events.at(-1).type, "yrby:error");
  assert.equal(el.events.filter(event => event.type === "yrby:synced").length, 1);
  assert.equal(el.inert, true);
  assert.equal(el.doc, undefined);
});

test("an element without a grant waits quietly until the attributes name a document", async t => {
  const { el, consumer, mount, change } = setup(t, { name: "body" });
  await mount();
  assert.equal(consumer.created.length, 0);
  assert.equal(el.events.length, 0);
  assert.equal(el.inert, true);
  change("grant", "g"); await tick();
  sync(consumer.created[0]); await el.whenSynced;
  assert.equal(el.events.length, 1);
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

const synced = el => el.events.filter(event => event.type === "yrby:synced");
const errors = el => el.events.filter(event => event.type === "yrby:error");
const settled = promise => { const state = { done: false }; promise.then(() => { state.done = true; }); return state; };

test("the synced event bubbles and carries the live session, document, provider, and lease", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const [event] = el.events;
  assert.equal(event.type, "yrby:synced");
  assert.equal(event.bubbles, true);
  const { session, doc, provider, lease, signal } = event.detail;
  assert.equal(session, el.session);
  assert.equal(doc, el.doc);
  assert.equal(provider, el.provider);
  assert.equal(lease.session, session);
  assert.equal(signal, lease.signal);
  assert.equal(signal.aborted, false);
});

test("a session discarded under a bound editor ends the binding silently and stays down until a render", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session, signal = el.events[0].detail.signal;
  session.discard();
  assert.equal(signal.aborted, true);
  assert.equal(el.session, undefined, "an aborted lease is gone before settle runs");
  await tick();
  assert.equal(el.inert, true);
  assert.equal(errors(el).length, 0, "a discard is the application's decision, not an error");
  assert.equal(consumer.created.length, 1, "a stalled element does not re-acquire on its own");
  const ready = settled(el.whenSynced);
  el.activate(); await tick();
  assert.equal(consumer.created.length, 2);
  assert.notEqual(el.session, session);
  sync(consumer.created[1]); await tick();
  assert.equal(ready.done, true);
  assert.equal(synced(el).length, 2);
});

test("a block during the first sync reports it, never announces, and waits for a render after retry", async t => {
  const { el, consumer, mount } = setup(t);
  await mount();
  const ready = settled(el.whenSynced);
  const sub = consumer.created[0];
  // Work queued before the first sync keeps the session alive after its editor is retired.
  el.session.doc.getText("content").insert(0, "early");
  sub.handlers.rejected();
  await tick();
  assert.equal(errors(el).length, 1);
  const { session } = errors(el)[0].detail;
  assert.equal(session.state, "blocked");
  // The application retries and the server answers, but the stalled element stays put.
  session.retry();
  await tick();
  sync(consumer.created.at(-1));
  await tick();
  assert.equal(session.state, "open");
  assert.equal(session.provider.status, "synced");
  assert.equal(synced(el).length, 0, "no announcement for a session the element gave up on");
  assert.equal(ready.done, false);
  assert.equal(el.inert, true);
  assert.equal(el.session, undefined);
  el.activate(); await tick();
  assert.equal(el.session, session, "the retried session is reused");
  assert.equal(synced(el).length, 1);
  assert.equal(el.inert, false);
});

test("discarding a blocked session leaves the stalled element quiet until a render binds a fresh one", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  consumer.created[0].handlers.rejected();
  await tick();
  const blocked = errors(el)[0].detail.session;
  const events = el.events.length;
  blocked.discard();
  await tick();
  assert.equal(el.events.length, events);
  assert.equal(consumer.created.length, 1);
  el.activate(); await tick();
  assert.notEqual(el.session, blocked);
  assert.equal(el.session.state, "open");
  sync(consumer.created.at(-1)); await tick();
  assert.equal(synced(el).length, 2);
});

test("a stalled element retries only on a render, a real attribute change, or re-insertion", async t => {
  const attributes = { grant: "g", name: "body" };
  const { el, consumer, mount, remove, change } = setup(t, attributes);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session;
  consumer.created[0].handlers.rejected();
  await tick();
  const reports = () => errors(el).length;
  assert.equal(reports(), 1);
  // Not triggers: the same value, an unobserved attribute, and the refresh URL.
  el.attributeChangedCallback("name", "body", "body");
  change("class", "busy");
  change("refresh", "/grant");
  await tick();
  assert.equal(reports(), 1);
  // Re-insertion retries: the session is still blocked, so it reports again.
  remove(); await mount();
  assert.equal(reports(), 2);
  // A real attribute change retries against the new document.
  change("name", "notes"); await tick();
  assert.equal(reports(), 2);
  assert.equal(el.session.descriptor.name, "notes");
  assert.equal(session.state, "blocked", "the old session keeps its queue for the application");
});

test("a same-value attribute callback keeps a bound editor bound", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const signal = el.events[0].detail.signal;
  el.attributeChangedCallback("grant", "g", "g");
  await tick();
  assert.equal(signal.aborted, false);
  assert.equal(el.inert, false);
  assert.equal(el.events.length, 1);
});

test("clearing the name detaches quietly, keeps pending edits, and restoring it rebinds the same session", async t => {
  const { el, consumer, mount, change } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session, signal = el.events[0].detail.signal;
  session.doc.getText("content").insert(0, "unsent");
  change("name", "");
  await tick();
  assert.equal(signal.aborted, true);
  assert.equal(el.doc, undefined);
  assert.equal(el.inert, true);
  assert.equal(el.events.length, 1, "an unnamed element reports nothing");
  assert.equal(session.state, "open");
  assert.equal(session.hasPending, true);
  change("name", "body"); await tick();
  assert.equal(el.session, session);
  assert.equal(el.doc.getText("content").toString(), "unsent");
  assert.equal(synced(el).length, 2);
});

test("retargeting before the first sync closes the unsynced session and a late sync of it announces nothing", async t => {
  const { el, consumer, mount, change } = setup(t);
  await mount();
  const old = el.session, oldSub = consumer.created[0];
  change("name", "notes"); await tick();
  assert.equal(old.state, "closed", "nothing needed the unsynced session");
  assert.equal(oldSub.removed, true);
  sync(oldSub); await tick();
  assert.equal(el.events.length, 0);
  assert.equal(el.inert, true);
  sync(consumer.created.at(-1)); await el.whenSynced;
  assert.equal(synced(el).length, 1);
  assert.equal(synced(el)[0].detail.session.descriptor.name, "notes");
});

test("a cached page with unsent edits rebinds to the same session and subscription when shown again", async t => {
  const { el, consumer, mount } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const session = el.session;
  session.doc.getText("content").insert(0, "unsent");
  el.deactivate();
  await tick();
  assert.equal(el.session, undefined);
  assert.equal(el.inert, true);
  assert.equal(session.state, "open", "the queue keeps the session alive");
  const ready = settled(el.whenSynced);
  el.activate(); await tick();
  assert.equal(el.session, session);
  assert.equal(consumer.created.length, 1, "no new subscription for a still-live session");
  assert.equal(el.doc.getText("content").toString(), "unsent");
  assert.equal(ready.done, true);
  assert.equal(synced(el).length, 2);
  assert.equal(el.inert, false);
});

test("the application's own inert value is parked once and restored on readiness", async t => {
  for (const original of [false, true]) {
    const { el, consumer, mount, change } = setup(t);
    el.inert = original;
    await mount();
    assert.equal(el.inert, true);
    assert.equal(el.getAttribute("data-yrby-inert"), String(original));
    // A retarget before readiness holds again; it must not park the library's own inert.
    change("name", "notes"); await tick();
    assert.equal(el.getAttribute("data-yrby-inert"), String(original));
    sync(consumer.created.at(-1)); await el.whenSynced;
    assert.equal(el.inert, original);
    assert.equal(el.getAttribute("data-yrby-inert"), null);
  }
});

test("a same-turn move keeps a live editor interactive throughout", async t => {
  const { el, consumer, mount, remove } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  remove();
  assert.equal(el.inert, false);
  const moved = mount();
  assert.equal(el.inert, false, "no inert flicker while the move settles");
  await moved;
  assert.equal(el.inert, false);
  assert.equal(el.getAttribute("data-yrby-inert"), null);
});

test("a grant refresh keeps the editor bound without a second announcement", async t => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ grant: "renewed" }), { status: 200 });
  t.after(() => { globalThis.fetch = original; });
  const { el, consumer, mount } = setup(t, { grant: "g", name: "body", refresh: "/grant" });
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const signal = el.events[0].detail.signal, session = el.session;
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.equal(consumer.created.at(-1).params.grant, "renewed");
  sync(consumer.created.at(-1)); await tick();
  assert.equal(signal.aborted, false);
  assert.equal(el.session, session);
  assert.equal(el.inert, false);
  assert.deepEqual(el.events.map(event => event.type), ["yrby:synced"]);
});

test("destroy releases a connected element, and only re-insertion binds it again", async t => {
  const { el, consumer, document, mount, remove } = setup(t);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const signal = el.events[0].detail.signal;
  el.destroy();
  assert.equal(signal.aborted, true);
  assert.equal(el.inert, true);
  document.dispatchEvent(new Event("turbo:render"));
  document.dispatchEvent(new Event("turbo:load"));
  await tick();
  assert.equal(el.session, undefined, "an unregistered element ignores page renders");
  assert.equal(consumer.created.length, 1);
  remove(); await mount();
  assert.ok(el.session);
  sync(consumer.created.at(-1)); await tick();
  assert.equal(synced(el).length, 2);
});

test("an acquisition that throws reports the error and stays stalled until a render", async t => {
  const { el, mount } = setup(t, undefined, Promise.resolve("not a consumer"));
  await mount();
  assert.equal(errors(el).length, 1);
  assert.ok(errors(el)[0].detail.error instanceof TypeError);
  assert.equal(errors(el)[0].detail.session, undefined);
  assert.equal(el.session, undefined);
  assert.equal(el.inert, true);
  await tick();
  assert.equal(errors(el).length, 1, "no retry loop");
  const consumer = fakeConsumer();
  YrbyDocumentElement.consumer = consumer;
  el.activate(); await tick();
  sync(consumer.created[0]); await el.whenSynced;
  assert.equal(synced(el).length, 1);
});

test("attributes that change without a callback are still honored on the next settle", async t => {
  const attributes = { grant: "g", name: "body" };
  const { el, consumer, mount } = setup(t, attributes);
  await mount(); sync(consumer.created[0]); await el.whenSynced;
  const signal = el.events[0].detail.signal;
  attributes.name = "notes"; // no attributeChangedCallback
  el.activate(); await tick();
  assert.equal(signal.aborted, true);
  assert.equal(el.session.descriptor.name, "notes");
});

test("the default consumer is loaded lazily, a failed load is forgotten, and a later render retries it", async t => {
  const hadDocument = "document" in globalThis, savedDocument = globalThis.document;
  t.after(() => { if (hadDocument) globalThis.document = savedDocument; else delete globalThis.document; });
  delete globalThis.document; // createConsumer needs a DOM to read its URL
  const { el, mount } = setup(t);
  YrbyDocumentElement.consumer = undefined;
  await mount();
  await new Promise(resolve => setTimeout(resolve, 20)); // the dynamic import settles in a later task
  assert.equal(errors(el).length, 1);
  assert.match(String(errors(el)[0].detail.error), /document is not defined/);
  // With a DOM, the retry creates a real consumer. Subscribing needs a socket
  // URL this stub cannot build, so the session blocks and reports itself.
  globalThis.document = { head: { querySelector: () => null }, createElement() { throw new Error("no socket in tests"); } };
  el.activate();
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(errors(el).length, 2);
  const { session } = errors(el)[1].detail;
  assert.equal(session.state, "blocked");
  assert.match(String(session.error), /no socket in tests/);
  assert.equal(typeof session.store.consumer.subscriptions.create, "function");
  // The loaded consumer is shared by later attempts.
  el.activate();
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(errors(el).at(-1).detail.session, session);
  session.discard();
});
