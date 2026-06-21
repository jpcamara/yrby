import { test } from "node:test";
import assert from "node:assert/strict";
import { ReliableSync } from "../dist/index.js";

// Test harness: capture sends, fake-merge by tagging, and control the timer.
function harness(opts = {}) {
  const sent = []; // [{ update, id }]
  const mergeCalls = []; // arrays passed to merge
  let tickFn = null;
  const rs = new ReliableSync({
    send: (update, id) => sent.push({ update, id }),
    merge: (updates) => {
      mergeCalls.push(updates);
      return { merged: updates.slice() }; // a distinct, inspectable value
    },
    setInterval: (fn) => {
      tickFn = fn;
      return 1;
    },
    clearInterval: () => {
      tickFn = null;
    },
    ...opts,
  });
  return { rs, sent, mergeCalls, tick: () => tickFn && tickFn(), hasTimer: () => tickFn !== null };
}

const u = (n) => new Uint8Array([n]); // a stand-in update

test("requires send and merge", () => {
  assert.throws(() => new ReliableSync({ merge: () => {} }), /send/);
  assert.throws(() => new ReliableSync({ send: () => {} }), /merge/);
});

test("queues while disconnected, replays the tail on connect", () => {
  const h = harness();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2));
  assert.equal(h.sent.length, 0, "nothing is sent before connecting");
  assert.equal(h.rs.hasPending, true);

  h.rs.onConnect();
  assert.equal(h.sent.length, 1, "one merged flush on connect");
  assert.deepEqual(h.sent[0].id, 2, "id is the highest seq in the batch");
  assert.deepEqual(h.mergeCalls[0], [u(1), u(2)], "the unacked tail is merged");
});

test("single pending update is sent without calling merge", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(7));
  assert.equal(h.mergeCalls.length, 0, "no merge for a single update");
  assert.deepEqual(h.sent.at(-1), { update: u(7), id: 1 });
});

test("ack prunes cumulatively (seq <= id)", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(1)); // seq 1
  h.rs.enqueue(u(2)); // seq 2
  h.rs.enqueue(u(3)); // seq 3
  assert.equal(h.rs.pending.length, 3);

  h.rs.onAck(2); // confirms seq 1 and 2
  assert.deepEqual(h.rs.pending.map((p) => p.seq), [3], "only seq 3 remains");

  h.rs.onAck(3);
  assert.equal(h.rs.hasPending, false, "queue drains once everything is acked");
});

test("reconnect resends the whole unacked tail", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  h.rs.onAck(1); // confirmed
  h.rs.enqueue(u(2));
  h.rs.enqueue(u(3));
  const before = h.sent.length;

  h.rs.onDisconnect();
  assert.equal(h.hasTimer(), false, "timer paused on disconnect");
  assert.equal(h.rs.hasPending, true, "queue is kept across the drop");

  h.rs.onConnect();
  assert.equal(h.sent.length, before + 1, "the unacked tail is replayed");
  assert.deepEqual(h.sent.at(-1).id, 3);
  assert.deepEqual(h.mergeCalls.at(-1), [u(2), u(3)]);
});

test("periodic tick retransmits the tail while unacked", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  const after = h.sent.length;
  h.tick();
  assert.equal(h.sent.length, after + 1, "a tick re-flushes the unacked tail");
  h.rs.onAck(1);
  h.tick();
  assert.equal(h.sent.length, after + 1, "nothing to resend once acked");
});

test("falls back to fire-and-forget after N unacked resends", () => {
  let fellBack = false;
  const h = harness({ maxUnconfirmedResends: 3, onFallback: () => (fellBack = true) });
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  for (let i = 0; i < 4; i++) h.tick(); // exceed the threshold with no ack

  assert.equal(h.rs.reliable, false, "reliable mode is disabled");
  assert.equal(fellBack, true, "onFallback fired");
  assert.equal(h.rs.hasPending, false, "queue cleared on fallback");
  assert.equal(h.hasTimer(), false, "timer stopped");

  // Post-fallback enqueues are sent immediately, no id, no queue.
  const before = h.sent.length;
  h.rs.enqueue(u(9));
  assert.deepEqual(h.sent.at(-1), { update: u(9), id: undefined });
  assert.equal(h.sent.length, before + 1);
  assert.equal(h.rs.hasPending, false);
});

test("an ack resets the fallback counter (slow but live link doesn't fall back)", () => {
  const h = harness({ maxUnconfirmedResends: 2 });
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  h.tick();
  h.tick();
  h.rs.onAck(1); // progress!
  h.rs.enqueue(u(2));
  for (let i = 0; i < 2; i++) h.tick();
  assert.equal(h.rs.reliable, true, "acks keep the connection out of fallback");
});

test("fallback delivers the tail one last time before dropping retention", () => {
  const h = harness({ maxUnconfirmedResends: 2 });
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2));
  const before = h.sent.length;
  for (let i = 0; i < 3; i++) h.tick(); // trip the fallback

  assert.equal(h.rs.reliable, false, "fell back");
  const afterFallback = h.sent.slice(before);
  assert.ok(afterFallback.length >= 1, "the tail was flushed during fallback");
  const last = h.sent.at(-1);
  assert.equal(last.id, undefined, "the final delivery is fire-and-forget (no id)");
  assert.equal(h.rs.hasPending, false, "retention dropped after the final flush");
});

test("onAck ignores malformed, negative, and impossible future acks", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2)); // seqs 1,2

  h.rs.onAck(NaN);
  h.rs.onAck("2"); // not a number at runtime
  h.rs.onAck(-1);
  h.rs.onAck(999); // future: beyond the highest pending seq
  assert.equal(h.rs.hasPending, true, "no invalid ack pruned the queue");
  assert.equal(h.rs.pending.length, 2);

  h.rs.onAck(1); // valid
  assert.equal(h.rs.pending.length, 1, "a valid ack prunes seq <= id");
});

test("the merged tail is memoized across retransmit ticks, invalidated on change", () => {
  const h = harness();
  h.rs.onConnect();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2)); // one merge for this flush
  const mergesAfterFlush = h.mergeCalls.length;

  h.tick();
  h.tick();
  assert.equal(h.mergeCalls.length, mergesAfterFlush, "retransmits reuse the memoized tail");

  h.rs.enqueue(u(3)); // tail changed -> next flush re-merges
  assert.equal(h.mergeCalls.length, mergesAfterFlush + 1, "enqueue invalidates the cache");
});
