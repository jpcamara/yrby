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
