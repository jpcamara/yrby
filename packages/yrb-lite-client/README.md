# yrb-lite-client

The **client core** for the [`yrb-lite`](https://github.com/jpcamara/yrb-lite)
y-websocket protocol — everything a Yjs provider needs *except the transport*.
Bring your own socket (ActionCable, AnyCable, raw WebSocket); this owns the
protocol.

Three layers, use whichever you need:

- **`ActionCableProvider`** — a ready-made Yjs provider for ActionCable /
  AnyCable. Pass a `Y.Doc`, a cable consumer, and a channel; it wires the
  subscription and you're collaborating. Awareness/presence automatically rides
  AnyCable's `whisper` when the consumer supports it (client-to-client, no server
  round-trip), and falls back to a normal server-relayed send on plain
  ActionCable — nothing to configure. Document updates always go through the
  server (recorded/acked).
- **`YProtocolSession`** — the transport-agnostic core. Binds to a `Y.Doc` (+ optional
  `Awareness`) and owns the y-protocols **message encode/decode**, the
  **sync-step handshake** (SyncStep1 / SyncStep2 / Update), **awareness**, and
  reliable delivery. Speaks raw `Uint8Array` frames; you wire any socket.
- **`ReliableSync`** — the zero-dependency reliable-delivery state machine on its
  own: ack-tracked queue, **sync-since-last-ack** (the unacked tail merged into
  one causally-complete delta), cumulative acks, retransmit + "server doesn't
  support acks" fallback, and reconnect replay. Compose it yourself if you
  already have your own framing.

## Install

```bash
npm install yrb-lite-client
```

`ActionCableProvider` and `YProtocolSession` need `yjs` and `y-protocols` (peers — your
app already has them), plus an ActionCable/AnyCable consumer. `ReliableSync` has
**no dependencies**; import it on its own via `yrb-lite-client/reliable` if
that's all you want.

Written in **TypeScript** and ships bundled type declarations, so TS projects get
full types (typed options, methods, and errors) with no `@types` package — and
plain-JS projects use the same compiled ESM with nothing extra to install.

## ActionCableProvider (the easy path)

```js
import { ActionCableProvider } from "yrb-lite-client";
import * as Y from "yjs";
import { createConsumer } from "@anycable/web"; // or @rails/actioncable

const doc = new Y.Doc();
const consumer = createConsumer();
const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: docId });

provider.connect(); // does not auto-connect — wire your editor binding first
// provider.awareness  -> the Awareness instance (a fresh one unless you pass opts.awareness)
// provider.synced     -> caught up with the server
// provider.hasPending -> unacked local edits in flight
// provider.destroy()  -> tear down
```

On the server, include `YrbLite::ActionCable::Sync` in a channel named
`DocumentChannel` (the [`yrb-lite-actioncable`](https://rubygems.org/gems/yrb-lite-actioncable)
gem), which enables AnyCable whispering on the stream automatically. Need a
different transport or framing? Drop down to `YProtocolSession` and supply your own
`send`.

## YProtocolSession

```js
import { YProtocolSession, toBase64, fromBase64 } from "yrb-lite-client";
import * as Y from "yjs";
import { Awareness } from "y-protocols/awareness";

const doc = new Y.Doc();
const awareness = new Awareness(doc);

const session = new YProtocolSession(doc, {
  awareness,
  // transmit one raw frame; `id` is set for reliable doc updates -> tag your envelope
  send: (frame, id) => {
    const payload = { update: toBase64(frame) };
    if (id !== undefined) payload.id = id;
    subscription.send(payload);
  },
});

// wire your transport's callbacks:
subscription.connected    = () => session.onConnect();      // handshake + replay
subscription.disconnected = () => session.onDisconnect();   // pause + clear presence
subscription.received = (msg) => {
  if (msg.ack !== undefined) return session.ack(msg.ack);   // reliable ack envelope
  const reply = session.receive(fromBase64(msg.update || msg.m)); // decode + apply
  if (reply) subscription.send({ update: toBase64(reply) });     // e.g. answer a SyncStep1
};
// session.synced -> caught up; session.hasPending -> unacked edits in flight
// session.destroy() -> detach listeners + stop retransmits
```

Local document edits and awareness changes are picked up automatically from the
doc's / awareness's `update` events — you never call anything for outbound edits.

Pass `onError(error, context)` (on either `ActionCableProvider` or
`YProtocolSession`) to observe dropped frames: a malformed or truncated message
is decoded defensively, dropped, and reported here rather than thrown into your
transport callback. Defaults to a `console.warn`.

## ReliableSync (standalone)

```js
import { ReliableSync } from "yrb-lite-client/reliable"; // zero-dep
import * as Y from "yjs";

const rs = new ReliableSync({
  send: (update, id) => { /* frame + transmit */ },
  merge: Y.mergeUpdates,
});

rs.enqueue(update);  // a local document update
rs.onAck(id);        // an { ack: id } arrived
rs.onConnect();      // (re)connected — replay the tail, resume retransmits
rs.onDisconnect();   // dropped — keep the queue, pause
```

## How it fits

The server counterpart — ack *generation*, gap detection, record-before-distribute
— is the `yrb-lite-actioncable` gem's `YrbLite::ActionCable::Sync`. This package
is the client half of the same protocol.

## License

MIT
