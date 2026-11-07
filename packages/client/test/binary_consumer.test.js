import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import { ActionCableProvider, createBinaryConsumer, CloseUnauthorized, MessageType } from "../dist/index.js";

// A fake WebSocket that records what the client writes and lets the test
// open, message, and close it.
function fakeSockets() {
  const sockets = [];
  class FakeSocket {
    static OPEN = 1;
    readyState = 0;
    sent = [];
    closedWith = null;
    constructor(url) { this.url = url; sockets.push(this); }
    send(data) { this.sent.push(new Uint8Array(data)); }
    close(code) { this.closedWith = code ?? 1000; }
    open() { this.readyState = 1; this.onopen?.(); }
    deliver(bytes) { this.onmessage?.({ data: new Uint8Array(bytes).buffer }); }
    deliverText(text) { this.onmessage?.({ data: text }); }
    drop(code = 1006) { this.readyState = 3; this.onclose?.({ code }); }
  }
  return { sockets, FakeSocket };
}

function readAuth(frame) {
  const d = decoding.createDecoder(frame);
  return { type: decoding.readVarUint(d), sub: decoding.readVarUint(d), identifier: decoding.readVarString(d) };
}

function setup() {
  const { sockets, FakeSocket } = fakeSockets();
  const doc = new Y.Doc();
  const errors = [];
  const consumer = createBinaryConsumer("ws://test/yjs/", { WebSocket: FakeSocket });
  const provider = new ActionCableProvider(doc, consumer, "RoomChannel", { name: "abc", grant: "signed" }, {
    onError: (error, context) => errors.push([context, error]),
  });
  return { sockets, doc, provider, errors };
}

test("the first frame is an auth message carrying the identifier", () => {
  const { sockets, provider } = setup();
  provider.connect();
  const socket = sockets[0];
  assert.equal(socket.url, "ws://test/yjs/");
  socket.open();

  assert.deepEqual(readAuth(socket.sent[0]), {
    type: 2,
    sub: 1,
    identifier: JSON.stringify({ channel: "RoomChannel", name: "abc", grant: "signed" }),
  });
  // The provider's SyncStep1 follows the auth frame.
  assert.equal(socket.sent[1][0], MessageType.Sync);
  provider.destroy();
});

test("a local edit goes out as an update frame with its id, and the ack clears it", () => {
  const { sockets, doc, provider } = setup();
  provider.connect();
  const socket = sockets[0];
  socket.open();
  socket.sent.length = 0;

  doc.getText("t").insert(0, "hi");
  const frame = socket.sent.find((f) => f[0] === 100);
  assert.ok(frame, "an update frame was sent");
  const d = decoding.createDecoder(frame);
  decoding.readVarUint(d);
  const id = decoding.readVarUint(d);
  assert.equal(decoding.readUint8(d), MessageType.Sync);
  assert.equal(provider.hasPending, true);

  const ack = encoding.createEncoder();
  encoding.writeVarUint(ack, 101);
  encoding.writeVarUint(ack, id);
  socket.deliver(encoding.toUint8Array(ack));
  assert.equal(provider.hasPending, false);
  provider.destroy();
});

test("server frames are applied to the document", () => {
  const { sockets, doc, provider } = setup();
  provider.connect();
  sockets[0].open();

  const other = new Y.Doc();
  other.getText("t").insert(0, "from server");
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MessageType.Sync);
  encoding.writeVarUint(e, 2); // update
  encoding.writeVarUint8Array(e, Y.encodeStateAsUpdate(other));
  sockets[0].deliver(encoding.toUint8Array(e));

  assert.equal(doc.getText("t").toString(), "from server");
  provider.destroy();
});

test("the keepalive empty awareness update is harmless", () => {
  const { sockets, provider, errors } = setup();
  provider.connect();
  sockets[0].open();
  sockets[0].deliver([MessageType.Awareness, 1, 0]);
  assert.equal(provider.status, "connected");
  assert.deepEqual(errors, []);
  provider.destroy();
});

test("a 4403 close rejects without reconnecting", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { sockets, FakeSocket } = fakeSockets();
  const rejected = [];
  const consumer = createBinaryConsumer("ws://test/yjs/", { WebSocket: FakeSocket });
  consumer.subscriptions.create({ channel: "RoomChannel" }, { rejected: () => rejected.push(true) });
  sockets[0].open();
  sockets[0].drop(CloseUnauthorized);
  t.mock.timers.tick(60_000);

  assert.equal(rejected.length, 1);
  assert.equal(sockets.length, 1);
});

test("any other close reconnects with backoff", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { sockets, FakeSocket } = fakeSockets();
  const events = [];
  const consumer = createBinaryConsumer("ws://test/yjs/", { WebSocket: FakeSocket });
  const sub = consumer.subscriptions.create({ channel: "RoomChannel" }, {
    connected: () => events.push("connected"),
    disconnected: () => events.push("disconnected"),
  });
  sockets[0].open();
  sockets[0].drop();
  t.mock.timers.tick(500);
  assert.equal(sockets.length, 2);
  sockets[1].open();
  assert.deepEqual(events, ["connected", "disconnected", "connected"]);

  sub.unsubscribe();
  assert.equal(sockets[1].closedWith, 1000);
});

test("a silent socket is closed so it reconnects", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { sockets, FakeSocket } = fakeSockets();
  const consumer = createBinaryConsumer("ws://test/yjs/", { WebSocket: FakeSocket });
  consumer.subscriptions.create({ channel: "RoomChannel" }, {});
  sockets[0].open();
  t.mock.timers.tick(9_000);
  sockets[0].deliver([MessageType.Awareness, 1, 0]);
  t.mock.timers.tick(9_000);
  assert.equal(sockets[0].closedWith, null);
  t.mock.timers.tick(1_000);
  assert.notEqual(sockets[0].closedWith, null);
});

test("text frames reach the handler as JSON", () => {
  const { sockets, FakeSocket } = fakeSockets();
  const received = [];
  const consumer = createBinaryConsumer("ws://test/yjs/", { WebSocket: FakeSocket });
  consumer.subscriptions.create({ channel: "RoomChannel" }, { received: (m) => received.push(m) });
  sockets[0].open();
  sockets[0].deliverText('{"notice":"full"}');
  assert.deepEqual(received, [{ notice: "full" }]);
});
