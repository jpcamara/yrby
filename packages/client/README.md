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

This is the element yrby-rails' `collaborative_document_tag` renders, and it
connects on its own, like `<turbo-cable-stream-source>` does for
`turbo_stream_from`. The tag gives it a signed grant. Import the element once
and it handles the rest:

```js
import "yrby-client/element";

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider);
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true });
});
```

`bindYourEditor` is your application's editor binding. Its cleanup must detach
Yjs listeners and disable or remove editor controls. It must not destroy the
document or provider, which the session owns, or disconnect the shared consumer.
The abort signal fires before yrby checks whether a final update still needs
delivery. Use it even if the editor has already left the DOM.

A document session owns the `Y.Doc`, the provider, and any unacknowledged
edits. The element attaches an editor to that session. Removing the last editor
clears presence and releases the session if it has nothing pending. A session
with pending edits keeps delivering them under its original grant until they
are acknowledged. A rejection stops the retries and keeps the work in memory
for recovery. It does not count as an acknowledgment.

Turbo previews are inert and create no document or provider. Cached markup
contains no CRDT snapshot. Restoring a page from history reattaches to a
pending session, or loads saved content from Rails. A new grant gets a separate
session, and the previous session's edits reach it through normal server sync.
This guarantee holds within a tab. It is not offline storage, and closing or
reloading the tab loses unacknowledged edits.

Moving the element within the same turn keeps its editor binding and document.
A clean remount after a delay reloads saved content, and it does not keep the
old undo stack or `Y.Doc`. Changing the grant, name, or channel aborts the old
binding at once and acquires a new session for the new tuple. Pending work
stays with the old session and its original authorization.

The element exposes its current `session`, `doc`, and `provider`. They are
unavailable before a session is acquired and while the element is retargeting,
and reading a getter never creates a document. `whenSynced` is always a
promise, even before the consumer is initialized. It resolves after the current
session's first catch-up, and it never resolves for an abandoned attachment.
The bubbling `yrby:synced` event fires once per attachment, with
`detail.signal` for cleanup. Synced does not mean the connection is online or
that every edit is acknowledged. Use `provider.synced` and `session.hasPending`
for those.

Import failures and subscription rejection emit `yrby:error` with
`detail.error`; rejection also includes the recoverable `detail.session`.
A blocked session stays inert. After retrying it, call `element.activate()`
to attach again, or remount the element. `element.destroy()` releases its
attachment and prevents automatic binding until it is reinserted; it does not
discard pending edits.

A `refresh` attribute names a same-origin URL that returns a new grant for
this document as JSON, `{ "grant": "..." }`. It is used when the server
rejects the subscription, which is what happens when a grant expires and the
cable reconnects. The session fetches the URL with the browser's session
cookies, resubscribes with the new grant, and keeps its document, its pending
edits, and its acknowledgment route. The application decides whether to issue
a grant, so the request is a fresh permission check. Nothing is fetched ahead
of time. One renewal is tried per rejection: if the refresh fails, or the
renewed grant is rejected as well, the session blocks as it would without the
attribute. The attribute is read when the session is acquired, and changing
it later does not rebind the editor.

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
infer a common record. Different consumers have separate scopes. Each session
adds an opaque `session_id` subscription parameter to isolate its
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

Use `attachment.setPresence(state)` for the focused editor and
`attachment.setPresence(null)` when it blurs. Views of the same session share
one presence; the last call wins. A binding can access its attachment through
`yrby:synced`'s `detail.attachment`.

`session.state` is `attached`, `draining`, `blocked`, or `closed`, independent
of the provider's live transport status. The store emits `change` with the
changed session in `event.detail`. Observe it to report delivery failures
after the originating page disappears.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});
```

Sessions keep their queues while the consumer is down and deliver when it
reconnects. A new consumer has its own store and never adopts another's work.

A blocked session keeps its document and pending edits in memory. `retry()`
reconnects with the session's current grant, which is the original one or the
last one its `refresh` URL returned; `discard()` drops the work. Cache
eviction never discards unsaved work. A grant supplied any other way, such as
a new element attribute, does not unblock a blocked session; it starts a
separate one.

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
provider.onStatusChange(({ status, pending }) => render(status, pending)); // returns an unsubscribe fn
//   "connecting"  -> subscription created, transport not up yet
//   "connected"   -> transport up, exchanging sync steps (show "syncing")
//   "synced"      -> caught up with the server
//   "disconnected"-> torn down via disconnect()/destroy()
//                    (a dropped transport ActionCable will retry shows as "connecting")
//   pending       -> true while local edits await acknowledgment; listeners
//                    fire when either status or pending changes

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
