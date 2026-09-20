import { test } from "node:test";
import assert from "node:assert/strict";
import { ReliableSync } from "../dist/index.js";

// Test harness: capture sends, fake-merge by tagging, and control the timer.
function harness(opts = {}) {
  const sent = []; // [{ update, id }]
  const mergeCalls = []; // arrays passed to merge
  let tickFn = null;
  let intervalMs = null;
  const rs = new ReliableSync({
    send: (update, id) => sent.push({ update, id }),
    merge: (updates) => {
      mergeCalls.push(updates);
      return { merged: updates.slice() }; // a distinct, inspectable value
    },
    setInterval: (fn, ms) => {
      tickFn = fn;
      intervalMs = ms;
      return 1;
    },
    clearInterval: () => {
      tickFn = null;
    },
    ...opts,
  });
  return {
    rs,
    sent,
    mergeCalls,
    tick: () => tickFn && tickFn(),
    hasTimer: () => tickFn !== null,
    intervalMs: () => intervalMs,
  };
}

const u = (n) => new Uint8Array([n]); // a stand-in update

test("requires send and merge", () => {
  assert.throws(() => new ReliableSync({ merge: () => {} }), /send/);
  assert.throws(() => new ReliableSync({ send: () => {} }), /merge/);
});

test("requires a positive resendInterval", () => {
  const base = { send: () => {}, merge: () => new Uint8Array() };
  assert.throws(() => new ReliableSync({ ...base, resendInterval: 0 }), /resendInterval/);
  assert.throws(() => new ReliableSync({ ...base, resendInterval: -1 }), /resendInterval/);
  assert.throws(() => new ReliableSync({ ...base, resendInterval: NaN }), /resendInterval/);
});

test("queues while disconnected, replays the tail on connect", () => {
  const h = harness();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2));
  assert.equal(h.sent.length, 0, "nothing is sent before connecting");
  assert.equal(h.rs.hasPending, true);

  h.rs.resume();
  assert.equal(h.sent.length, 1, "one merged flush on connect");
  assert.deepEqual(h.sent[0].id, 2, "id is the highest seq in the batch");
  assert.deepEqual(h.mergeCalls[0], [u(1), u(2)], "the unacked tail is merged");
});

test("single pending update is sent without calling merge", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(7));
  assert.equal(h.mergeCalls.length, 0, "no merge for a single update");
  assert.deepEqual(h.sent.at(-1), { update: u(7), id: 1 });
});

test("ack prunes cumulatively (seq <= id)", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1)); // seq 1
  h.rs.enqueue(u(2)); // seq 2
  h.rs.enqueue(u(3)); // seq 3
  assert.equal(h.rs.pending.length, 3);

  h.rs.acknowledge(2); // confirms seq 1 and 2
  assert.deepEqual(h.rs.pending.map((p) => p.seq), [3], "only seq 3 remains");

  h.rs.acknowledge(3);
  assert.equal(h.rs.hasPending, false, "queue drains once everything is acked");
});

test("reconnect resends the whole unacked tail", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  h.rs.acknowledge(1); // confirmed
  h.rs.enqueue(u(2));
  h.rs.enqueue(u(3));
  const before = h.sent.length;

  h.rs.pause();
  assert.equal(h.hasTimer(), false, "timer paused on disconnect");
  assert.equal(h.rs.hasPending, true, "queue is kept across the drop");

  h.rs.resume();
  assert.equal(h.sent.length, before + 1, "the unacked tail is replayed");
  assert.deepEqual(h.sent.at(-1).id, 3);
  assert.deepEqual(h.mergeCalls.at(-1), [u(2), u(3)]);
});

test("periodic tick retransmits the tail while unacked", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  const after = h.sent.length;
  h.tick();
  assert.equal(h.sent.length, after + 1, "a tick re-flushes the unacked tail");
  h.rs.acknowledge(1);
  h.tick();
  assert.equal(h.sent.length, after + 1, "nothing to resend once acked");
});

test("unacked updates stay retained and keep retransmitting until acked", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  const before = h.sent.length;
  for (let i = 0; i < 10; i++) h.tick();

  assert.equal(h.sent.length, before + 10, "each tick retransmits the pending tail");
  assert.equal(h.rs.hasPending, true, "the update is retained without an ack");
  assert.equal(h.hasTimer(), true, "the retransmit timer remains active");

  h.rs.acknowledge(1);
  assert.equal(h.rs.hasPending, false, "ack drains the retained update");
  assert.equal(h.hasTimer(), false, "the retransmit timer stops once the queue drains");
});

test("onAck ignores malformed, negative, and impossible future acks", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2)); // seqs 1,2

  h.rs.acknowledge(NaN);
  h.rs.acknowledge("2"); // not a number at runtime
  h.rs.acknowledge(-1);
  h.rs.acknowledge(999); // future: beyond the highest pending seq
  assert.equal(h.rs.hasPending, true, "no invalid ack pruned the queue");
  assert.equal(h.rs.pending.length, 2);

  h.rs.acknowledge(1); // valid
  assert.equal(h.rs.pending.length, 1, "a valid ack prunes seq <= id");
});

test("the merged tail is memoized across retransmit ticks, invalidated on change", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  h.rs.enqueue(u(2)); // one merge for this flush
  const mergesAfterFlush = h.mergeCalls.length;

  h.tick();
  h.tick();
  assert.equal(h.mergeCalls.length, mergesAfterFlush, "retransmits reuse the memoized tail");

  h.rs.enqueue(u(3)); // tail changed -> next flush re-merges
  assert.equal(h.mergeCalls.length, mergesAfterFlush + 1, "enqueue invalidates the cache");
});

test("connect with an empty queue does not start the retransmit timer", () => {
  const h = harness();
  h.rs.resume();
  assert.equal(h.hasTimer(), false, "no timer while nothing is pending");
});

test("the retransmit timer restarts when a new update is enqueued after drain", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  h.rs.acknowledge(1);
  assert.equal(h.hasTimer(), false, "timer stopped after drain");

  h.rs.enqueue(u(2));
  assert.equal(h.hasTimer(), true, "timer restarted for the new pending update");
});

test("destroy while connected stops the timer and ignores further enqueues", () => {
  const h = harness();
  h.rs.resume();
  h.rs.enqueue(u(1));
  assert.equal(h.hasTimer(), true);

  h.rs.destroy();
  assert.equal(h.hasTimer(), false, "timer stopped on destroy");
  assert.equal(h.rs.hasPending, false, "queue cleared on destroy");

  h.rs.enqueue(u(2));
  assert.equal(h.sent.length, 1, "no sends after destroy");
  h.tick();
  assert.equal(h.sent.length, 1, "no retransmits after destroy");
});

test("resendInterval is forwarded to setInterval", () => {
  const h = harness({ resendInterval: 2500 });
  h.rs.resume();
  h.rs.enqueue(u(1));
  assert.equal(h.intervalMs(), 2500);
});
