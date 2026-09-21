import { test } from "node:test";
import assert from "node:assert/strict";
import { ReliableSync } from "../dist/index.js";

// End-to-end property under a lossy link: every enqueued update eventually
// reaches the server and the client's queue drains, without a real socket or
// yjs. The "merge" concatenates seq ranges so the server can verify coverage,
// and a deterministic drop pattern exercises lost sends AND lost acks.
test("no acknowledged update is lost under deterministic loss", () => {
  // Server state: the set of seqs it has durably "applied".
  const serverHas = new Set();
  let client; // set below so the link can deliver acks back

  let sendN = 0;
  const dropSend = (i) => i % 3 === 0; // drop every 3rd outbound frame
  let ackN = 0;
  const dropAck = (i) => i % 4 === 0; // drop every 4th ack

  // A merged "update" contains the sequence bytes it covers (our fake encoding).
  const link = {
    send(update, id) {
      if (dropSend(++sendN)) return; // frame lost in transit
      for (const seq of update) serverHas.add(seq); // server applies (idempotent)
      if (dropAck(++ackN)) return; // ack lost on the way back
      client.acknowledge(id);
    },
  };

  client = new ReliableSync({
    send: link.send,
    merge: (updates) => Uint8Array.from(updates.flatMap(update => [...update])),
    setInterval: () => 1,
    clearInterval: () => {},
  });
  // Our fake updates are single-byte Uint8Arrays; ReliableSync assigns each a seq,
  // which happens to match since we enqueue one update per seq in order.
  const TOTAL = 50;

  client.resume();
  for (let s = 1; s <= TOTAL; s++) {
    client.enqueue(Uint8Array.of(s));
    client.retransmit(); // a retransmit opportunity interleaved with sends
  }

  // Healing phase: keep ticking; surviving acks prune, surviving sends fill gaps.
  for (let round = 0; round < 200 && client.hasPending; round++) client.retransmit();

  assert.equal(client.hasPending, false, "client queue fully drains");
  for (let s = 1; s <= TOTAL; s++) {
    assert.ok(serverHas.has(s), `server received update ${s}`);
  }
  assert.equal(serverHas.size, TOTAL, "server has exactly the updates that were sent");
});
