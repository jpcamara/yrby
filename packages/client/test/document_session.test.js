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

test("matching attachments share one document and queue; consumer scopes are isolated", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  assert.equal(first.session, second.session);
  assert.equal(consumer.created.length, 1);
  sync(consumer.created[0], "saved");
  await first.session.whenSynced;
  first.release();
  assert.equal(second.session.state, "attached");
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
  const attachment = store.acquire(descriptor), session = attachment.session;
  sync(consumer.created[0]);
  attachment.signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "final edit"));
  attachment.release();
  attachment.release();
  assert.equal(session.state, "draining");
  assert.equal(session.hasPending, true);
  assert.equal(consumer.created.length, 1, "detach must not replace the provider");
  ack(consumer.created[0]);
  await tick();
  assert.equal(session.state, "closed");
  assert.equal(session.doc.isDestroyed, true);
});

test("reattachment between acknowledgment and disposal preserves the live document", async t => {
  const { consumer, store } = setup(t);
  const attachment = store.acquire(descriptor), session = attachment.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "edit");
  attachment.release();
  ack(consumer.created[0]);
  const reattached = store.acquire(descriptor);
  await tick();
  assert.equal(reattached.session, session);
  assert.equal(session.state, "attached");
  assert.equal(session.doc.isDestroyed, false);
});

test("an edit added after ack is retained even if the previous ack wait already resolved", async t => {
  const { consumer, store } = setup(t);
  const attachment = store.acquire(descriptor), session = attachment.session;
  sync(consumer.created[0]);
  session.doc.getText("content").insert(0, "one");
  attachment.release();
  ack(consumer.created[0]);
  const another = store.acquire(descriptor);
  session.doc.getText("content").insert(3, "two");
  another.release();
  await tick();
  assert.equal(session.state, "draining");
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
  ack(originalSub); // A late old callback cannot prune a replacement's queue.
  assert.equal(replacement.session.hasPending, true);
});

test("rejection retains the final editor update and retry uses original authorization", async t => {
  const { consumer, store } = setup(t);
  const attachment = store.acquire(descriptor), session = attachment.session;
  sync(consumer.created[0]);
  attachment.signal.addEventListener("abort", () => session.doc.getText("content").insert(0, "recover me"));
  consumer.created[0].handlers.rejected();
  await tick();
  assert.equal(attachment.signal.aborted, true);
  assert.equal(session.state, "blocked");
  assert.equal(session.provider, undefined);
  assert.equal(session.hasPending, true);
  assert.equal(store.sessions[0], session);
  const copy = session.exportRecovery();
  const restored = new Y.Doc();
  Y.applyUpdate(restored, copy.update);
  assert.equal(restored.getText("content").toString(), "recover me");
  restored.destroy();
  copy.pending.fill(0);
  assert.notDeepEqual(session.exportRecovery().pending, copy.pending, "recovery is a defensive copy");
  session.retry();
  const retry = consumer.created.at(-1);
  assert.equal(retry.params.grant, "g");
  assert.notEqual(retry.params.session_id, consumer.created[0].params.session_id);
  retry.handlers.connected();
  ack(retry);
  await tick();
  assert.equal(session.state, "closed");
});

test("suspension prevents new sessions and navigation from reopening the consumer", async t => {
  const { consumer, store } = setup(t);
  const first = store.acquire(descriptor);
  sync(consumer.created[0]);
  first.session.doc.getText("content").insert(0, "pending");
  store.suspend();
  first.release();
  const fresh = store.acquire({ ...descriptor, grant: "fresh" });
  assert.equal(consumer.created.length, 1);
  assert.equal(first.session.hasPending, true);
  assert.equal(fresh.session.provider, undefined);
  store.resume();
  assert.equal(consumer.created.length, 3);
  assert.equal(first.session.hasPending, true);
});

test("removing an unfocused attachment does not clear the focused editor's presence", t => {
  const { store } = setup(t);
  const first = store.acquire(descriptor), second = store.acquire(descriptor);
  first.setPresence({ user: "Alice", cursor: 1 });
  second.setPresence({ user: "Alice", cursor: 2 });
  first.release();
  assert.deepEqual(second.session.provider.awareness.getLocalState(), { user: "Alice", cursor: 2 });
  second.setPresence(null);
  assert.equal(second.session.provider.awareness.getLocalState(), null);
});

test("blocked work is observable and only explicit discard removes it", t => {
  const { consumer, store } = setup(t);
  const states = [];
  store.addEventListener("change", event => states.push(event.detail.state));
  const attachment = store.acquire(descriptor);
  consumer.created[0].handlers.rejected();
  assert.ok(states.includes("blocked"));
  assert.equal(store.sessions.length, 1);
  attachment.session.discard();
  assert.equal(store.sessions.length, 0);
});
