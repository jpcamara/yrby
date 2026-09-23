import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import { DocumentSessionStore } from "../dist/index.js";
import { fakeConsumer, sync, ack, tick } from "./session_helpers.js";
const descriptor = { grant: "g", name: "body" };
function setup(t) {
  const consumer = fakeConsumer();
  const store = DocumentSessionStore.for(consumer);
  t.after(() => { for (const session of store.sessions) session.discard(); });
  return { consumer, store };
}

test("one consumer has one canonical document store", t => {
  const { consumer, store } = setup(t);
  assert.throws(() => new DocumentSessionStore(consumer), /DocumentSessionStore.for/);
  assert.equal(DocumentSessionStore.for(consumer), store);
  const first = store.acquire(descriptor);
  const second = DocumentSessionStore.for(consumer).acquire(descriptor);
  assert.equal(first.session, second.session);
  assert.equal(consumer.created.length, 1);
});

test("sessions expose no direct lease acquisition or release methods", t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  assert.equal(session.attach, undefined);
  assert.equal(session.release, undefined);
  let cleanups = 0;
  lease.signal.addEventListener("abort", () => { cleanups++; });
  lease.release();
  lease.release();
  assert.equal(cleanups, 1);
  assert.equal(lease.signal.aborted, true);
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
  assert.equal(session.attach, undefined);
});

test("even a retained internal acquisition method cannot attach to a closed session", t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  // Deliberately reflect on the internal operation to exercise its terminal-state guard.
  const key = Object.getOwnPropertySymbols(Object.getPrototypeOf(session)).find(key => key.description === "attachLease");
  const acquire = session[key].bind(session);
  session.discard();
  assert.throws(acquire, /Cannot acquire a closed document session/);
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
  assert.equal(lease.signal.aborted, true);
  assert.equal(consumer.created.length, 1);
  assert.deepEqual(store.sessions, []);
});

test("discarding from an acquisition observer announces closure once", t => {
  const { store } = setup(t);
  const seen = [];
  store.addEventListener("change", event => {
    const session = event.detail;
    seen.push(session.state);
    if (session.state === "open") session.discard();
  });
  const lease = store.acquire(descriptor);
  assert.equal(lease.signal.aborted, true);
  assert.equal(lease.session.doc.isDestroyed, true);
  assert.deepEqual(seen, ["open", "closed"]);
  assert.deepEqual(store.sessions, []);
});

test("closed sessions ignore deferred provider errors", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  consumer.created[0].unsubscribe = () => { throw new Error("late unsubscribe failure"); };
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  lease.release();
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(session.error, undefined);
  assert.deepEqual(seen, ["closed"]);
});

test("an initial connection failure returns an aborted lease on a blocked session", t => {
  const { consumer, store } = setup(t);
  consumer.subscriptions.create = () => { throw new Error("cannot subscribe"); };
  const lease = store.acquire(descriptor);
  assert.equal(lease.signal.aborted, true);
  assert.equal(lease.session.state, "blocked");
  assert.match(String(lease.session.error), /cannot subscribe/);
  assert.equal(lease.session.doc.isDestroyed, false);
  assert.deepEqual(store.sessions, [lease.session]);
});

test("observers see cleanup-triggered retry only after its replacement lease is acquired", t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), session = first.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "keep me");
  let replacement;
  let cleanupFinished = false;
  first.signal.addEventListener("abort", () => {
    session.retry();
    replacement = store.acquire(descriptor);
    cleanupFinished = true;
  });
  const seen = [];
  store.addEventListener("change", event => seen.push({
    state: event.detail.state,
    cleanupFinished,
    replacementLive: replacement?.signal.aborted === false,
  }));
  consumer.created[0].handlers.rejected();
  assert.deepEqual(seen, [{ state: "open", cleanupFinished: true, replacementLive: true }]);
  assert.equal(replacement.session, session);
  assert.equal(session.hasPending, true);
  assert.equal(consumer.created.length, 2);
});

test("matching leases share one document and queue; consumer scopes are isolated", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  assert.equal(first.session, second.session);
  assert.equal(consumer.created.length, 1);
  sync(consumer.created[0], "saved");
  await first.session.whenSynced;
  first.release();
  assert.equal(second.session.state, "open");
  assert.equal(second.session.doc.getText("content").toString(), "saved");
  const other = setup(t).store.acquire(descriptor);
  assert.notEqual(other.session, second.session);
  const doc = second.session.doc;
  second.release();
  assert.equal(doc.isDestroyed, true);
  assert.equal(store.sessions.length, 0);
});

test("editor cleanup can flush a final edit before disposal checks the queue", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  lease.signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "final edit"));
  lease.release();
  lease.release();
  assert.equal(session.state, "open");
  assert.equal(session.hasPending, true);
  assert.equal(consumer.created.length, 1, "detach must not replace the provider");
  ack(consumer.created[0]);
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
});

test("a session with no editors closes on the acknowledgment and a later acquire starts fresh", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "edit");
  lease.release();
  assert.equal(session.state, "open");
  ack(consumer.created[0]);
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
  const reattached = store.acquire(descriptor);
  await tick();
  assert.notEqual(reattached.session, session);
  assert.equal(reattached.session.state, "open");
  assert.equal(reattached.session.doc.isDestroyed, false);
});

test("an edit added while a lease is live is retained after the earlier ack", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "one");
  ack(consumer.created[0]);
  session.doc.getText("content").insert(3, "two");
  lease.release();
  await tick();
  assert.equal(session.state, "open");
  assert.equal(session.hasPending, true);
  ack(consumer.created[0]);
  await tick();
  assert.equal(session.state, "closed");
});

test("fresh grants and replacement lifetimes use different acknowledgment routes", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor);
  const originalSub = consumer.created[0];
  sync(originalSub);
  first.session.doc.getText("content").insert(0, "original");
  first.release();
  const fresh = store.acquire({ ...descriptor, grant: "fresh" });
  assert.notEqual(fresh.session, first.session);
  assert.equal(fresh.session.hasPending, false);
  ack(originalSub);
  await tick();
  const replacement = store.acquire(descriptor);
  const replacementSub = consumer.created.at(-1);
  assert.notEqual(replacementSub.params.session_id, originalSub.params.session_id);
  sync(replacementSub);
  replacement.session.doc.getText("content").insert(0, "new edit");
  // Cable routes incoming messages by serialized subscription identifier, even
  // if the old handler is gone. Old ACKs must never reach the new queue.
  const oldIdentifier = JSON.stringify(originalSub.params);
  const oldAck = originalSub.sent.filter(message => message.id !== undefined).at(-1).id;
  for (const sub of consumer.created) {
    if (!sub.removed && JSON.stringify(sub.params) === oldIdentifier) sub.handlers.received({ ack: oldAck });
  }
  assert.equal(replacement.session.hasPending, true);
});

test("rejection retains the final editor update and retry uses original authorization", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  lease.signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "recover me"));
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(lease.signal.aborted, true);
  assert.equal(session.state, "blocked");
  assert.equal(session.provider.status, "disconnected");
  assert.equal(session.hasPending, true);
  assert.equal(store.sessions[0], session);
  assert.equal(session.doc.getText("content").toString(), "recover me");
  session.retry();
  const retry = consumer.created.at(-1);
  assert.equal(retry.params.grant, "g");
  assert.equal(retry.params.session_id, consumer.created[0].params.session_id, "same queue, same ack route");
  retry.handlers.connected();
  ack(retry);
  await tick();
  assert.equal(session.state, "closed");
});

test("blocked work is observable and only explicit discard removes it", t => {
  const { consumer, store } = setup(t);
  const states = [];
  store.addEventListener("change", event => states.push(event.detail.state));
  const lease = store.acquire(descriptor);
  consumer.created[0].handlers.rejected();
  assert.ok(states.includes("blocked"));
  assert.equal(store.sessions.length, 1);
  lease.session.discard();
  assert.equal(store.sessions.length, 0);
});

function stubFetch(t, respond) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => { calls.push({ url, init }); return respond(url, init); };
  t.after(() => { globalThis.fetch = original; });
  return calls;
}
const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const refreshing = { ...descriptor, refresh: "/grant" };

test("rejection with a refresh URL renews the grant once and resumes the same session", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const lease = store.acquire(refreshing), session = lease.session, provider = session.provider;
  const first = consumer.created[0];
  sync(first);
  session.doc.getText("content").insert(0, "keep me");
  first.handlers.rejected();
  await tick(); await tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/grant");
  assert.equal(calls[0].init.credentials, "same-origin");
  assert.equal(calls[0].init.headers.Accept, "application/json");
  assert.equal(session.state, "open");
  assert.equal(lease.signal.aborted, false);
  assert.equal(session.provider, provider, "the same provider resubscribes");
  const renewed = consumer.created.at(-1);
  assert.notEqual(renewed, first);
  assert.equal(renewed.params.grant, "renewed");
  assert.equal(renewed.params.session_id, first.params.session_id, "the ack route is unchanged");
  assert.equal(session.descriptor.grant, "g", "the descriptor keeps the original grant");
  renewed.handlers.connected();
  assert.ok(renewed.sent.some(message => message.id !== undefined), "pending work replays on the renewed subscription");
  ack(renewed);
  await tick();
  assert.equal(session.hasPending, false);
});

test("a failed refresh blocks the session with the refresh error", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ error: "forbidden" }, 403));
  const lease = store.acquire(refreshing), session = lease.session;
  sync(consumer.created[0]);
  lease.signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "recover me"));
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.equal(calls.length, 1);
  assert.equal(session.state, "blocked");
  assert.match(String(session.error), /403/);
  assert.equal(lease.signal.aborted, true);
  assert.equal(session.hasPending, true);
  assert.equal(consumer.created.length, 1, "no resubscription without a grant");
});

test("a renewed grant that is rejected in turn blocks without fetching again, and retry uses it", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const lease = store.acquire(refreshing), session = lease.session;
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  const renewed = consumer.created.at(-1);
  assert.equal(renewed.params.grant, "renewed");
  renewed.handlers.rejected();
  await tick(); await tick();
  assert.equal(calls.length, 1, "one renewal per rejection");
  assert.equal(session.state, "blocked");
  assert.equal(lease.signal.aborted, true);
  session.retry();
  assert.equal(consumer.created.at(-1).params.grant, "renewed", "retry reconnects with the current grant");
});

test("a reconnect after a successful renewal may renew again on the next rejection", async t => {
  const { consumer, store } = setup(t);
  let n = 0;
  const calls = stubFetch(t, () => jsonResponse({ grant: `renewed-${++n}` }));
  const lease = store.acquire(refreshing), session = lease.session;
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  const renewed = consumer.created.at(-1);
  renewed.handlers.connected();
  renewed.handlers.rejected();
  await tick(); await tick();
  assert.equal(calls.length, 2);
  assert.equal(consumer.created.at(-1).params.grant, "renewed-2");
  assert.equal(session.state, "open");
  assert.equal(lease.signal.aborted, false);
});

test("without a refresh URL a rejection blocks immediately and nothing is fetched", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "unused" }));
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(calls.length, 0);
  assert.equal(session.state, "blocked");
  assert.equal(lease.signal.aborted, true);
});

test("a refresh request carries a timeout signal so a silent endpoint cannot hold the session offline", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  store.acquire(refreshing);
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.ok(calls[0].init.signal instanceof AbortSignal, "fetch is given an abort signal");
  assert.equal(calls[0].init.signal.aborted, false);
});

test("a consumer that throws while resubscribing with a renewed grant blocks the session", async t => {
  const { consumer, store } = setup(t);
  stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const lease = store.acquire(refreshing), session = lease.session;
  sync(consumer.created[0]);
  const create = consumer.subscriptions.create;
  consumer.subscriptions.create = () => { throw new Error("socket gone"); };
  t.after(() => { consumer.subscriptions.create = create; });
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.equal(session.state, "blocked");
  assert.match(String(session.error), /socket gone/);
  assert.equal(lease.signal.aborted, true);
});

test("the phase transitions are the only ones allowed, and each notifies once", async t => {
  const { consumer, store } = setup(t);
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "work");

  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(session.state, "blocked");
  const afterBlock = seen.length;
  assert.equal(seen.at(-1), "blocked");
  assert.equal(seen.filter(s => s === "blocked").length, 1, "blocking notified once");

  // Already blocked: a second failure changes nothing and says nothing.
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(session.state, "blocked");
  assert.equal(seen.length, afterBlock, "no event for a repeated block");
  assert.equal(session.hasPending, true, "the queue is untouched");

  // blocked -> closed is legal, and the work goes with it.
  session.discard();
  assert.equal(session.state, "closed");
  assert.equal(seen.at(-1), "closed");
  assert.equal(store.sessions.length, 0);

  // closed is terminal: nothing reopens or re-ends it.
  const afterClose = seen.length;
  session.discard();
  session.retry();
  assert.equal(session.state, "closed");
  assert.equal(seen.length, afterClose, "a closed session stays quiet");
});


test("a new lease waits for the in-flight refresh instead of subscribing with the rejected grant", async t => {
  const { consumer, store } = setup(t);
  let respond;
  const calls = stubFetch(t, () => new Promise(resolve => { respond = resolve; }));
  const first = store.acquire(refreshing);
  consumer.created[0].handlers.rejected();
  const second = store.acquire(refreshing);
  assert.equal(second.session, first.session);
  assert.equal(second.session.state, "open");
  assert.equal(consumer.created.length, 1);
  respond(jsonResponse({ grant: "renewed" }));
  await tick(); await tick();
  assert.equal(calls.length, 1);
  assert.equal(consumer.created.length, 2);
  assert.equal(consumer.created[1].params.grant, "renewed");
  assert.equal(first.signal.aborted, false);
  assert.equal(second.signal.aborted, false);
});

for (const outcome of ["success", "failure"]) {
  test(`a stale refresh ${outcome} cannot change a session that has blocked and retried`, async t => {
    const { consumer, store } = setup(t);
    let respond, fail;
    stubFetch(t, () => new Promise((resolve, reject) => { respond = resolve; fail = reject; }));
    const lease = store.acquire(refreshing), session = lease.session;
    sync(consumer.created[0]);
    session.doc.getText("content").insert(0, "keep me");
    consumer.created[0].handlers.rejected();
    // The provider is public: an application can reconnect before refresh ends.
    session.provider.connect();
    consumer.created.at(-1).handlers.rejected();
    assert.equal(session.state, "blocked");
    session.retry();
    const retry = consumer.created.at(-1);
    const subscriptions = consumer.created.length;
    if (outcome === "success") respond(jsonResponse({ grant: "stale" }));
    else fail(new Error("stale failure"));
    await tick(); await tick();
    assert.equal(session.state, "open");
    assert.equal(session.error, undefined);
    assert.equal(session.hasPending, true);
    assert.equal(consumer.created.length, subscriptions);
    assert.equal(retry.removed, false);
    assert.equal(session.provider.channelParams.grant, "g");
  });
}

test("retrying and acquiring from an abort handler preserves the replacement connection and lease", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "keep me");
  let replacement;
  lease.signal.addEventListener("abort", () => {
    session.retry();
    replacement = store.acquire(descriptor);
  });
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(session.state, "open");
  assert.equal(session.provider.status, "connecting");
  assert.equal(consumer.created.length, 2);
  assert.equal(consumer.created[1].removed, false);
  assert.equal(replacement.session, session);
  assert.equal(replacement.signal.aborted, false);
  sync(consumer.created[1]);
  ack(consumer.created[1]);
  assert.equal(session.hasPending, false);
  assert.equal(session.state, "open");
});

test("acquiring from a closing session's abort handler creates a live replacement", t => {
  const { store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  let replacement;
  lease.signal.addEventListener("abort", () => { replacement = store.acquire(descriptor); });
  session.discard();
  assert.equal(session.state, "closed");
  assert.notEqual(replacement.session, session);
  assert.equal(replacement.session.state, "open");
  assert.equal(replacement.signal.aborted, false);
  assert.equal(replacement.session.doc.isDestroyed, false);
  assert.deepEqual(store.sessions, [replacement.session]);
});


test("a renewed grant can reconnect before its first acceptance without refreshing again", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const first = store.acquire(refreshing);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  first.session.provider.disconnect();
  const second = store.acquire(refreshing);
  assert.equal(second.session, first.session);
  assert.equal(consumer.created.length, 3);
  assert.equal(consumer.created.at(-1).params.grant, "renewed");
  consumer.created.at(-1).handlers.rejected();
  assert.equal(second.session.state, "blocked");
  assert.equal(calls.length, 1);
});
