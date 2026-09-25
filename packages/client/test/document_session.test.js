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

test("one consumer has one canonical document store", async t => {
  const { consumer, store } = setup(t);
  assert.throws(() => new DocumentSessionStore(consumer), /DocumentSessionStore.for/);
  assert.equal(DocumentSessionStore.for(consumer), store);
  assert.equal(store.changed, undefined);
  const first = store.acquire(descriptor);
  const second = DocumentSessionStore.for(consumer).acquire(descriptor);
  assert.equal(first.session, second.session);
  await tick();
  assert.equal(consumer.created.length, 1);
});

test("sessions expose no direct lease acquisition or release methods", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  assert.equal(session.attach, undefined);
  assert.equal(session.release, undefined);
  let cleanups = 0;
  lease.signal.addEventListener("abort", () => { cleanups++; });
  lease.release();
  lease.release();
  assert.equal(cleanups, 1);
  assert.equal(lease.signal.aborted, true);
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
  assert.equal(session.attach, undefined);
});

test("even a retained internal acquisition method cannot attach to a closed session", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
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

test("discarding from an acquisition observer announces closure once", async t => {
  const { store } = setup(t);
  const seen = [];
  store.addEventListener("change", event => {
    const session = event.detail;
    seen.push(session.state);
    if (session.state === "open") session.discard();
  });
  const lease = store.acquire(descriptor);
  await tick();
  assert.equal(lease.signal.aborted, true);
  assert.equal(lease.session.doc.isDestroyed, true);
  assert.deepEqual(seen, ["open", "closed"]);
  assert.deepEqual(store.sessions, []);
});

test("closed sessions ignore deferred provider errors", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
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

test("an initial connection failure returns an aborted lease on a blocked session", async t => {
  const { consumer, store } = setup(t);
  consumer.subscriptions.create = () => { throw new Error("cannot subscribe"); };
  const lease = store.acquire(descriptor);
  await tick();
  assert.equal(lease.signal.aborted, true);
  assert.equal(lease.session.state, "blocked");
  assert.match(String(lease.session.error), /cannot subscribe/);
  assert.equal(lease.session.doc.isDestroyed, false);
  assert.deepEqual(store.sessions, [lease.session]);
});

test("observers see cleanup-triggered retry only after its replacement lease is acquired", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), session = first.session;
  await tick();
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
  await tick();
  assert.deepEqual(seen, [{ state: "open", cleanupFinished: true, replacementLive: true }]);
  assert.equal(replacement.session, session);
  assert.equal(session.hasPending, true);
  assert.equal(consumer.created.length, 2);
});

test("matching leases share one document and queue; consumer scopes are isolated", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  assert.equal(first.session, second.session);
  await tick();
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
  await tick();
  assert.equal(doc.isDestroyed, true);
  assert.equal(store.sessions.length, 0);
});

test("editor cleanup can flush a final edit before disposal checks the queue", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
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
  await tick();
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "edit");
  lease.release();
  assert.equal(session.state, "open");
  ack(consumer.created[0]);
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
  const retry = consumer.created.at(-1);
  assert.equal(retry.params.grant, "g");
  assert.equal(retry.params.session_id, consumer.created[0].params.session_id, "same queue, same ack route");
  retry.handlers.connected();
  ack(retry);
  await tick();
  assert.equal(session.state, "closed");
});

test("blocked work is observable and only explicit discard removes it", async t => {
  const { consumer, store } = setup(t);
  const states = [];
  store.addEventListener("change", event => states.push(event.detail.state));
  const lease = store.acquire(descriptor);
  await tick();
  consumer.created[0].handlers.rejected();
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
  assert.equal(consumer.created.at(-1).params.grant, "renewed", "retry reconnects with the current grant");
});

test("a reconnect after a successful renewal may renew again on the next rejection", async t => {
  const { consumer, store } = setup(t);
  let n = 0;
  const calls = stubFetch(t, () => jsonResponse({ grant: `renewed-${++n}` }));
  const lease = store.acquire(refreshing), session = lease.session;
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
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
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(seen.at(-1), "closed");
  assert.equal(store.sessions.length, 0);

  // closed is terminal: nothing reopens or re-ends it.
  const afterClose = seen.length;
  session.discard();
  session.retry();
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(seen.length, afterClose, "a closed session stays quiet");
});


test("a new lease waits for the in-flight refresh instead of subscribing with the rejected grant", async t => {
  const { consumer, store } = setup(t);
  let respond;
  const calls = stubFetch(t, () => new Promise(resolve => { respond = resolve; }));
  const first = store.acquire(refreshing);
  await tick();
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
  await tick();
    sync(consumer.created[0]);
    session.doc.getText("content").insert(0, "keep me");
    consumer.created[0].handlers.rejected();
    // The provider is public: an application can reconnect before refresh ends.
    session.provider.connect();
    consumer.created.at(-1).handlers.rejected();
    assert.equal(session.state, "blocked");
    session.retry();
    await tick();
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
  await tick();
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
  await tick();
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  first.session.provider.disconnect();
  const second = store.acquire(refreshing);
  assert.equal(second.session, first.session);
  await tick();
  assert.equal(consumer.created.length, 3);
  assert.equal(consumer.created.at(-1).params.grant, "renewed");
  consumer.created.at(-1).handlers.rejected();
  assert.equal(second.session.state, "blocked");
  assert.equal(calls.length, 1);
});

test("acquire requires a grant and a name and creates nothing without them", t => {
  const { consumer, store } = setup(t);
  for (const input of [{ name: "body" }, { grant: "g" }, { grant: "", name: "body" }, { grant: "g", name: "" }]) {
    assert.throws(() => store.acquire(input), /requires a grant and name/);
  }
  assert.deepEqual(store.sessions, []);
  assert.equal(consumer.created.length, 0);
});

test("the default channel and an explicit one name the same session; another channel does not", async t => {
  const { consumer, store } = setup(t);
  const implicit = store.acquire(descriptor);
  const explicit = store.acquire({ ...descriptor, channel: "Y::DocumentChannel" });
  const other = store.acquire({ ...descriptor, channel: "NotesChannel" });
  assert.equal(implicit.session, explicit.session);
  assert.notEqual(other.session, implicit.session);
  assert.equal(implicit.session.descriptor.channel, "Y::DocumentChannel");
  assert.equal(Object.isFrozen(implicit.session.descriptor), true);
  await tick();
  assert.deepEqual(consumer.created.map(sub => sub.params.channel), ["Y::DocumentChannel", "NotesChannel"]);
});

test("the first acquirer's refresh URL is the one the shared session renews with", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const first = store.acquire({ ...descriptor, refresh: "/first" });
  const second = store.acquire({ ...descriptor, refresh: "/second" });
  assert.equal(second.session, first.session);
  assert.equal(first.session.descriptor.refresh, "/first");
  await tick();
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.deepEqual(calls.map(call => call.url), ["/first"]);
});

test("a session first acquired without a refresh URL blocks on rejection even if a later lease names one", async t => {
  const { consumer, store } = setup(t);
  const calls = stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const first = store.acquire(descriptor);
  store.acquire(refreshing);
  assert.equal(first.session.descriptor.refresh, undefined);
  await tick();
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.equal(calls.length, 0);
  assert.equal(first.session.state, "blocked");
});

test("presence is set only through a live lease and cleared when the last lease is released", async t => {
  const { store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  const { awareness } = first.session.provider;
  assert.equal(awareness.getLocalState(), null, "no cursor before an editor sets one");
  first.setPresence({ user: "jp" });
  assert.deepEqual(awareness.getLocalState(), { user: "jp" });
  first.release();
  first.setPresence({ user: "stale" });
  assert.deepEqual(awareness.getLocalState(), { user: "jp" }, "a released lease cannot change presence");
  second.setPresence({ user: "rowan" });
  assert.deepEqual(awareness.getLocalState(), { user: "rowan" });
  second.release();
  assert.equal(awareness.getLocalState(), null, "the last release clears presence");
});

test("releasing one of several leases keeps the session open and connected", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  await tick();
  first.release();
  await tick();
  assert.equal(second.session.state, "open");
  assert.equal(second.signal.aborted, false);
  assert.equal(consumer.created[0].removed, false);
  assert.deepEqual(store.sessions, [second.session]);
});

test("an idle session closes on the last release, unsubscribes, and announces closure once", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  await tick();
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  lease.release();
  assert.equal(session.state, "open", "closing waits for settle");
  await tick();
  assert.equal(session.state, "closed");
  assert.deepEqual(seen, ["closed"]);
  assert.deepEqual(store.sessions, []);
  assert.equal(consumer.created[0].removed, true);
  assert.equal(session.doc.isDestroyed, true);
});

test("discard leaves the store before editor cleanup runs, then destroys the document", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "unsaved");
  const during = {};
  lease.signal.addEventListener("abort", () => {
    during.sessions = store.sessions;
    during.state = session.state;
    during.docDestroyed = session.doc.isDestroyed;
  });
  session.discard();
  assert.deepEqual(during, { sessions: [], state: "closed", docDestroyed: false });
  assert.equal(session.doc.isDestroyed, true);
  assert.equal(session.hasPending, false);
});

test("a lease acquired while blocked is kept for retry and does not connect until then", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), session = first.session;
  await tick();
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(first.signal.aborted, true);
  const waiting = store.acquire(descriptor);
  assert.equal(waiting.session, session);
  await tick();
  assert.equal(waiting.signal.aborted, false, "only leases held at the block are retired");
  assert.equal(session.state, "blocked");
  assert.equal(consumer.created.length, 1, "a blocked session does not reconnect for a new lease");
  session.retry();
  await tick();
  assert.equal(session.state, "open");
  assert.equal(consumer.created.length, 2);
  assert.equal(waiting.signal.aborted, false);
});

test("a blocked session is never closed implicitly, even with no leases or pending work", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  assert.equal(session.hasPending, false);
  assert.equal(session.state, "blocked");
  assert.deepEqual(store.sessions, [session]);
  // Retrying a session nobody needs lets the idle rule close it.
  session.retry();
  await tick();
  assert.equal(session.state, "closed");
  assert.deepEqual(store.sessions, []);
});

test("retry outside the blocked state changes nothing and notifies nobody", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  await tick();
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  session.retry();
  await tick();
  assert.deepEqual(seen, []);
  assert.equal(consumer.created.length, 1);
  assert.equal(consumer.created[0].removed, false);
  assert.equal(lease.signal.aborted, false);
});

test("retry clears the block error and notifies once", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "keep me");
  consumer.created[0].handlers.rejected();
  await tick();
  assert.match(String(session.error), /rejected/);
  const seen = [];
  store.addEventListener("change", event => seen.push({ state: event.detail.state, error: event.detail.error }));
  session.retry();
  assert.equal(session.state, "open");
  assert.equal(session.error, undefined);
  await tick();
  assert.deepEqual(seen, [{ state: "open", error: undefined }]);
});

test("a provider error outside rejection is recorded and announced without blocking", async t => {
  const { consumer, store } = setup(t);
  const lease = store.acquire(descriptor), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  await tick();
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  consumer.created[0].handlers.received({ update: "%%% not base64 %%%" });
  await tick();
  assert.ok(session.error, "the error is exposed");
  assert.equal(session.state, "open");
  assert.equal(lease.signal.aborted, false);
  assert.deepEqual(seen, ["open"]);
});

test("discarding while a refresh is in flight ignores its late grant", async t => {
  const { consumer, store } = setup(t);
  let respond;
  stubFetch(t, () => new Promise(resolve => { respond = resolve; }));
  const lease = store.acquire(refreshing), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(session.state, "open", "refreshing is an open substate");
  assert.equal(lease.signal.aborted, false, "editors survive a refresh");
  const seen = [];
  store.addEventListener("change", event => seen.push(event.detail.state));
  session.discard();
  await tick();
  respond(jsonResponse({ grant: "late" }));
  await tick(); await tick();
  assert.equal(session.state, "closed");
  assert.equal(consumer.created.length, 1, "no resubscription for a closed session");
  assert.deepEqual(seen, ["closed"], "the late grant says nothing");
});

test("a rejection while refreshing blocks, and the late grant cannot reopen the session", async t => {
  const { consumer, store } = setup(t);
  let respond;
  const calls = stubFetch(t, () => new Promise(resolve => { respond = resolve; }));
  const lease = store.acquire(refreshing), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  session.provider.connect();
  consumer.created.at(-1).handlers.rejected();
  await tick();
  assert.equal(session.state, "blocked");
  assert.equal(lease.signal.aborted, true);
  const subscriptions = consumer.created.length;
  respond(jsonResponse({ grant: "late" }));
  await tick(); await tick();
  assert.equal(calls.length, 1);
  assert.equal(session.state, "blocked");
  assert.equal(consumer.created.length, subscriptions);
  assert.match(String(session.error), /rejected/);
});

for (const [label, respond, pattern] of [
  ["no grant field", () => jsonResponse({}), /returned no grant/],
  ["an empty grant", () => jsonResponse({ grant: "" }), /returned no grant/],
  ["a non-string grant", () => jsonResponse({ grant: 42 }), /returned no grant/],
  ["a null body", () => jsonResponse(null), /returned no grant/],
  ["a body that is not JSON", () => new Response("<html>", { status: 200 }), /JSON/],
  ["a network failure or timeout", () => { throw new DOMException("The operation timed out.", "TimeoutError"); }, /timed out/],
]) {
  test(`a refresh answered with ${label} blocks without resubscribing`, async t => {
    const { consumer, store } = setup(t);
    stubFetch(t, respond);
    const lease = store.acquire(refreshing), session = lease.session;
    await tick();
    sync(consumer.created[0]);
    consumer.created[0].handlers.rejected();
    await tick(); await tick();
    assert.equal(session.state, "blocked");
    assert.match(String(session.error), pattern);
    assert.equal(lease.signal.aborted, true);
    assert.equal(consumer.created.length, 1);
    session.retry();
    await tick();
    assert.equal(consumer.created.at(-1).params.grant, "g", "retry falls back to the original grant");
  });
}

test("a successful refresh keeps the session open throughout and never reports an error", async t => {
  const { consumer, store } = setup(t);
  stubFetch(t, () => jsonResponse({ grant: "renewed" }));
  const seen = [];
  store.addEventListener("change", event => seen.push({ state: event.detail.state, error: event.detail.error }));
  const lease = store.acquire(refreshing), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  consumer.created[0].handlers.rejected();
  await tick(); await tick();
  sync(consumer.created.at(-1));
  await tick();
  assert.ok(seen.length > 0);
  assert.deepEqual(seen.filter(entry => entry.state !== "open" || entry.error !== undefined), []);
  assert.equal(lease.signal.aborted, false);
  assert.equal(session.provider.status, "synced");
});

test("an earlier refresh answering during a later refresh cannot install its grant", async t => {
  const { consumer, store } = setup(t);
  const responders = [];
  stubFetch(t, () => new Promise(resolve => { responders.push(resolve); }));
  const lease = store.acquire(refreshing), session = lease.session;
  await tick();
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "keep me");
  consumer.created[0].handlers.rejected(); // first refresh starts
  session.provider.connect();
  consumer.created.at(-1).handlers.rejected(); // rejected while refreshing: blocks
  session.retry();
  await tick();
  consumer.created.at(-1).handlers.rejected(); // second refresh starts
  await tick();
  assert.equal(responders.length, 2);
  const subscriptions = consumer.created.length;
  responders[0](jsonResponse({ grant: "stale" }));
  await tick(); await tick();
  assert.equal(consumer.created.length, subscriptions, "the first answer belongs to an abandoned refresh");
  responders[1](jsonResponse({ grant: "fresh" }));
  await tick(); await tick();
  assert.equal(consumer.created.at(-1).params.grant, "fresh");
  assert.equal(session.provider.channelParams.grant, "fresh");
  assert.equal(session.state, "open");
});
