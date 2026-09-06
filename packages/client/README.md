# yrby-client

The **client core** for the [`yrby`](https://github.com/jpcamara/yrby)
y-websocket protocol — everything a Yjs provider needs *except the transport*.
Bring your own socket (ActionCable, AnyCable, raw WebSocket); this owns the
protocol.

Three layers, use whichever you need:

- **`ActionCableProvider`** — a ready-made Yjs provider for ActionCable /
  AnyCable. Pass a `Y.Doc`, a cable consumer, and a channel; it wires the
  subscription and you're collaborating. Awareness/presence rides AnyCable
  `whisper` when available via an awareness-only envelope and falls back to
  normal sends on plain ActionCable; document updates always go through the
  server as reliable recorded/acked updates.
- **`YProtocolSession`** — the transport-agnostic core. Binds to a `Y.Doc` (+ optional
  `Awareness`) and owns the y-protocols **message encode/decode**, the
  **sync-step handshake** (SyncStep1 / SyncStep2 / Update), **awareness**, and
  reliable delivery. Speaks raw `Uint8Array` frames; you wire any socket.
- **`ReliableSync`** — the zero-dependency reliable-delivery state machine on its
  own: ack-tracked queue, **sync-since-last-ack** (the unacked tail merged into
  one causally-complete delta), cumulative acks, retransmit, and reconnect
  replay. Compose it yourself if you already have your own framing.

## Install

```bash
npm install yrby-client
```

`ActionCableProvider` and `YProtocolSession` need `yjs` and `y-protocols` (peers — your
app already has them), plus an ActionCable/AnyCable consumer. `ReliableSync` has
**no dependencies**; import it on its own via `yrby-client/reliable` if
that's all you want.

Written in **TypeScript** and ships bundled type declarations, so TS projects get
full types (typed options, methods, and errors) with no `@types` package — and
plain-JS projects use the same compiled ESM with nothing extra to install.

## `<yrby-document>` (the easiest path)

The auto-connecting element behind yrby-rails' `collaborative_document_tag`,
the way `<turbo-cable-stream-source>` sits behind `turbo_stream_from`. The tag
renders it with a signed grant; importing the element once is the whole
wiring:

```js
import "yrby-client/element";

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider);
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true });
});
```

`bindYourEditor` is your application's editor binding. Its cleanup must detach
Yjs listeners and disable or remove editor controls. It must not destroy the
session-owned document/provider or disconnect the shared consumer. The attachment's abort
signal runs cleanup before yrby checks whether any final update needs delivery.
Use this signal even if the editor has already left the DOM.

A document session owns the `Y.Doc`, provider, and unacknowledged edits. The
element attaches an editor to that session. Removing the last editor clears
presence and releases a clean session. A pending session keeps delivering
through its original grant until acknowledged. Rejection stops retries and
retains recoverable work in memory; it does not count as acknowledgment.

Turbo previews are inert and create no document or provider. Cached markup
contains no CRDT snapshot. History restoration reattaches to a pending session
or loads saved content from Rails. A fresh grant creates a separate session;
the previous session's edits reach it through normal server synchronization.
This is an in-tab delivery guarantee, not persistent offline storage across
closing or reloading the tab.

Same-turn DOM moves retain the editor binding and document. A clean delayed
remount reconstructs saved content; it need not retain the old undo stack or
Y.Doc identity. Changing grant, name, or channel aborts the old binding
immediately and acquires a new session for the complete new tuple. Pending
work stays with the old session and its original authorization.

The element exposes its current `session`, `doc`, and `provider`. Before
acquisition or during retargeting these are unavailable; no unowned document
is created by reading a getter. `whenSynced` is always a promise, even before
consumer initialization. It resolves after the current session's first
catch-up, and an abandoned attachment's wait stays unresolved. The bubbling
`yrby:synced` event fires once per attachment, with `detail.signal` for cleanup.
Readiness does not imply the connection is currently online or every edit is
acknowledged. Use `provider.synced` and `session.hasPending` for those states.

Import failures and subscription rejection emit `yrby:error` with
`detail.error`; rejection also includes the recoverable `detail.session`.
A blocked session stays inert. After retrying it, call `element.activate()`
to attach again, or remount the element. `element.destroy()` releases its
attachment and prevents automatic binding until it is reinserted; it does not
discard pending edits.

Install `@rails/actioncable`, `yjs`, and `y-protocols` for the default element.
All default elements share one consumer, including its in-flight import.
For AnyCable assign an ActionCable-compatible consumer before adding elements:

```js
import { YrbyDocumentElement } from "yrby-client/element";
import { createConsumer } from "@anycable/web";

YrbyDocumentElement.consumer = createConsumer();
```

## Document sessions

A store is scoped to one consumer. Matching `{ channel, grant, name }` tuples
share a document and queue. Grants are compared exactly, never decoded to
infer a common record. Different consumers have separate scopes. Each provider
lifetime adds an opaque `session_id` subscription parameter to isolate its
acknowledgments; this parameter never selects or authorizes a server document.

Headless workflows can hold an explicit attachment through their own lifetime:

```js
import { DocumentSessionStore } from "yrby-client";

const store = DocumentSessionStore.for(consumer);
const attachment = store.acquire({ grant, name: "body" });
const { session } = attachment;
await session.whenSynced;
// Work with session.doc; keep attachment until your workflow is finished.
attachment.release(); // idempotent; pending work continues delivering
```

Multiple views share one local presence identity. Use
`attachment.setPresence(state)` for the focused editor and
`attachment.setPresence(null)` when it blurs. Removing an unfocused view will
not clear another view's presence. A binding can access its attachment through
`yrby:synced`'s `detail.attachment`.

`session.state` is `attached`, `draining`, `blocked`, or `closed`, independent
of the provider's live transport status. Both sessions and stores emit `change`
events; a store event carries the changed session in `event.detail`. Observe
the store to report delivery failures after the originating page disappears.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});

store.suspend(); // explicitly stop managed network activity, retaining work
store.resume();  // resume this consumer scope, including detached pending work
```

Use store suspension for managed sessions rather than relying on
transport-specific consumer disconnect behavior. Navigation never reconnects
a suspended scope. Applications changing accounts must suspend/unmount the old
scope and handle its retained work; a new consumer does not adopt it.

A blocked session's `exportRecovery()` returns defensive copies of its full
Yjs `update`, its `pending` tail, and its immutable `descriptor`. `retry()`
retries only the original authorization. The application can export these
bytes or explicitly call `discard()`; cache eviction never discards unsaved
work. Recovery is memory-only, and its memory use grows with retained work.
No fresh grant is implicitly treated as a renewal of blocked authorization.

Custom persistence integrations can still use `provider.pendingUpdate` and
`provider.restorePendingUpdate(bytes)`. Restore saved full state through
`applyRemoteUpdate` first, then restore only the pending tail before connecting.
`provider.whenAcknowledged` resolves when its queue empties; it remains pending
if the provider is destroyed before acknowledgment.

## ActionCableProvider (the easy path)

```js
import { ActionCableProvider } from "yrby-client";
import * as Y from "yjs";
import { createConsumer } from "@anycable/web"; // or @rails/actioncable

const doc = new Y.Doc();
const consumer = createConsumer();
const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: docId });

provider.connect(); // does not auto-connect — wire your editor binding first

// Observe the connection (one signal, no separate "sync" event):
provider.onStatusChange(({ status }) => render(status)); // returns an unsubscribe fn
//   "connecting"  -> subscription created, transport not up yet
//   "connected"   -> transport up, exchanging sync steps (show "syncing")
//   "synced"      -> caught up with the server
//   "disconnected"-> torn down via disconnect()/destroy()
//                    (a dropped transport ActionCable will retry shows as "connecting")

// provider.status     -> the current status (same union as above)
// provider.awareness  -> the provider's Awareness instance (always a fresh one)
// provider.synced     -> caught up with the server
// provider.whenSynced -> Promise for the FIRST catch-up (see below)
// provider.hasPending -> unacked local edits in flight
// provider.destroy()  -> tear down
```

Most rich-text bindings seed an empty document when they mount, so binding
before the server's state arrives makes each client insert its own
top-level node. Wait for the first sync before creating the editor:

```js
provider.connect();
await provider.whenSynced; // resolves immediately if already synced
// now hand the doc to the editor binding
```

It resolves once, on the first catch-up, and stays resolved across later
reconnects. Use `onStatusChange` to track the live connection.

Callbacks from superseded subscriptions are ignored after `disconnect()` or
`destroy()`. A consumer that invokes its callbacks during subscription creation
is supported: the provider waits until creation returns before handling them.
These guards are separate from the managed session's unique acknowledgment route.

On `disconnect()` / `destroy()` — and on browser `pagehide` — the provider
broadcasts a presence removal so peers drop your cursor immediately instead of
waiting for the awareness timeout. `destroy()` is synchronous (the unsubscribe is
deferred one microtask so that removal flushes first) and tears down the
`Awareness` it created. (`ActionCableProvider` always creates its own; to bring
your own `Awareness`, drop down to `YProtocolSession`, which leaves it for you to
own.)

On the server, include `Y::ActionCable` in a channel named
`DocumentChannel` (the [`yrby-rails`](https://rubygems.org/gems/yrby-rails)
gem). The server subscribes document broadcasts and AnyCable awareness whispers
on separate streams, so the document stream is not whisper-enabled. Need a
different transport or framing? Drop down to `YProtocolSession` and supply your
own `send`.

The provider uses one JSON envelope shape:

```txt
client -> server document frame      { update: "<base64 frame>", id: 42 }
server -> client document frame      { update: "<base64 frame>" }
server -> client acknowledgement     { ack: 42 }
AnyCable awareness whisper           { awareness: "<base64 awareness frame>" }
```

## YProtocolSession

```js
import { YProtocolSession, toBase64, fromBase64 } from "yrby-client";
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
  const reply = session.receive(fromBase64(msg.update));     // decode + apply
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
import { ReliableSync } from "yrby-client/reliable"; // zero-dep
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

Pending updates are retained and replayed until the server acknowledges them.
Document delivery stays queued and ack-tracked for the lifetime of the session.

## How it fits

The server counterpart — ack *generation*, gap detection, record-before-distribute
— is the `yrby-rails` gem's `Y::ActionCable`. This package
is the client half of the same protocol.

## License

MIT
