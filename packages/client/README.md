# yrby-client

The JavaScript client for yrby's Yjs protocol. Most Rails apps import
`yrby-client/element` and bind an editor when it emits `yrby:synced`.
Applications that manage their own editor lifetime can use
`DocumentSessionStore` instead.

Each layer has one job:

- **`<yrby-document>`** attaches an editor while its page is live. It does not
  attach one on a Turbo or Turbolinks preview.
- **`DocumentSessionStore`** keeps a document and its pending work after an
  editor detaches. A lease is how a caller holds on to a session.
- **`ActionCableProvider`** owns one ActionCable or AnyCable subscription and
  translates its JSON envelopes to protocol frames.
- **`YProtocolSession`** handles the Yjs handshake, frames, and awareness without
  depending on a particular transport.
- **`ReliableSync`** keeps local updates until the server acknowledges them,
  then replays the unacknowledged tail after a reconnect.

`<yrby-document>` uses each lower layer in that order. You can also use the
provider, protocol session, or zero-dependency delivery core on its own.

### How the classes relate

```mermaid
flowchart TD
  Adapter["TurboAdapter<br/>one per page"]
  Element["&lt;yrby-document&gt;<br/>YrbyDocumentElement"]
  Consumer["CableConsumer<br/>ActionCable or AnyCable, shared by the page"]
  Store["DocumentSessionStore<br/>one per consumer"]
  Session["DocumentSession<br/>one per document"]
  Lease["DocumentLease<br/>one per holder"]
  Doc["Y.Doc"]
  Provider["ActionCableProvider"]
  Awareness["Awareness<br/>presence"]
  Subscription["Cable subscription<br/>one per connect()"]
  Protocol["YProtocolSession"]
  Delivery["ReliableSync"]

  Adapter -->|"activate / deactivate"| Element
  Element -->|"acquire()"| Store
  Store -->|"finds or creates"| Session
  Element -->|"holds while bound"| Lease
  Lease -->|"is a hold on"| Session
  Session -->|"owns"| Doc
  Session -->|"owns for its whole life"| Provider
  Provider -->|"owns"| Awareness
  Provider -->|"owns"| Protocol
  Provider -->|"creates via"| Consumer
  Consumer -->|"returns"| Subscription
  Protocol -->|"owns"| Delivery
  Protocol -.->|"listens for edits"| Doc
```

Each arrow reads as a sentence, for example "DocumentSession owns
ActionCableProvider for its whole life." Signals go back up the other way. The
provider reports status and rejections to its session. A session that blocks
or is discarded aborts its leases, and that releases the element's editor.
Several elements that name the same document share one session. Pending edits
are kept by that session after the last element is gone.

## Install

```bash
npm install yrby-client
```

`ActionCableProvider` needs `yjs`, `y-protocols`, and an ActionCable/AnyCable
consumer. `YProtocolSession` needs `yjs` and `y-protocols`, but takes raw frames
from any transport. `ReliableSync` has **no dependencies**; import it on its own
via `yrby-client/reliable` if that's all you want.

Written in **TypeScript** and ships bundled type declarations, so TS projects get
full types (typed options, methods, and errors) with no `@types` package — and
plain-JS projects use the same compiled ESM with nothing extra to install.

## `<yrby-document>` (the easiest path)

yrby-rails' `collaborative_document_tag` renders this element and gives it a
signed grant. Like `<turbo-cable-stream-source>` with `turbo_stream_from`, it
connects on its own once the element is imported:

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

The element listens for both Turbo and Turbolinks 5 lifecycle events. A
cached preview is inert and creates no document or provider, and the cached
markup holds no CRDT snapshot. When a page is restored from history, the
element reattaches to a pending session if there is one, or loads the saved
content from Rails. A new grant gets its own session, and the previous
session's edits reach it through normal server sync. All of this holds within
one tab. It is not offline storage. Closing or reloading the tab loses
unacknowledged edits.

Moving the element within the same turn keeps its editor binding and document.
Remounting it after a delay reloads saved content. The old `Y.Doc` and undo
stack are gone. Changing the grant, name, or channel aborts the old binding
right away and acquires a session for the new tuple. Pending work is kept by
the old session under its original authorization.

The element exposes its current `session`, `doc`, and `provider`. They are
unavailable before a session is acquired and while the element is retargeting.
Reading a getter never creates a document. `whenSynced` is always a promise,
even before the consumer is initialized. It resolves after the current
session's first catch-up. If the lease is abandoned, that promise is left
unresolved. The bubbling `yrby:synced` event fires once per lease and carries
`detail.signal` for cleanup. Synced does not mean the connection is online or
that every edit is acknowledged. Check `provider.synced` and
`session.hasPending` for those.

Import failures and subscription rejections emit `yrby:error` with
`detail.error`. A rejection also includes `detail.session`, which you can
retry. While its session is blocked, the element is inert. After you retry the
session, call `element.activate()` to attach again, or remount the element.
`element.destroy()` releases the lease and stops automatic binding until the
element is reinserted. It does not discard pending edits.

A `refresh` attribute names a same-origin URL that returns a new grant for
this document as JSON, `{ "grant": "..." }`. The session uses it when the
server rejects the subscription, which is what happens when a grant expires
and the cable reconnects. It fetches the URL with the browser's session
cookies and resubscribes with the new grant. The document, the pending edits,
and the acknowledgment route all carry over. The application decides whether
to issue a grant, so each request is a fresh permission check. Nothing is
fetched ahead of time. The session tries one renewal per rejection. If the
refresh fails, takes longer than 15 seconds, or the renewed grant is rejected
too, the session blocks, the same as it would without the attribute. The
attribute is read when the session is acquired. Changing it later does not
rebind the editor.

The default element needs `@rails/actioncable`, `yjs`, and `y-protocols`. All
default elements share one consumer, and they share the import while it is
still loading. For AnyCable, assign an ActionCable-compatible consumer before
adding any elements:

```js
import { YrbyDocumentElement } from "yrby-client/element";
import { createConsumer } from "@anycable/web";

YrbyDocumentElement.consumer = createConsumer();
```

## Document sessions

A store belongs to one consumer. Two acquisitions with the same
`{ channel, grant, name }` share one document and one queue. Grants are
compared as strings; the client does not decode them to guess that two grants
point at the same record. Different consumers have separate stores. Each
session adds an opaque `session_id` subscription parameter so the server can
route acknowledgments to it. The server does not use that parameter to select
or authorize a document.

A headless workflow can hold a lease for as long as it runs:

```js
import { DocumentSessionStore } from "yrby-client";

const store = DocumentSessionStore.for(consumer);
const lease = store.acquire({ grant, name: "body" });
const { session } = lease;
await session.whenSynced;
// Work with session.doc; keep lease until your workflow is finished.
lease.release(); // idempotent; pending work continues delivering
```

Call `lease.setPresence(state)` when an editor gains focus and
`lease.setPresence(null)` when it blurs. All views of one session share one
presence, so the last call wins. A binding gets its lease from
`yrby:synced`'s `detail.lease`.

`session.state` is `open`, `blocked`, or `closed`. It is separate from the
provider's transport status. The store emits `change` with the session in
`event.detail`. Listen for it to report delivery failures after the page that
made the edits is gone.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});
```

Sessions keep their queues while the consumer is down and deliver when it
reconnects. A new consumer gets a new store. It does not pick up another
consumer's queued work.

A blocked session keeps its document and pending edits in memory. `retry()`
reconnects with the session's current grant, meaning the original one or the
last one its `refresh` URL returned. `discard()` drops the work. Cache
eviction does not discard unsaved work. A grant that arrives any other way,
such as a new element attribute, starts a separate session. It does not
unblock the blocked one.

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

After `disconnect()` or `destroy()`, callbacks from the old subscription are
ignored. A consumer may invoke callbacks while it is still creating the
subscription; the provider holds those until creation returns. These guards
are separate from the acknowledgment route a managed session sets up for
itself.

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
subscription.connected    = () => session.resume();         // handshake + replay
subscription.disconnected = () => session.pause();          // keep the queue, clear presence
subscription.received = (msg) => {
  if (msg.ack !== undefined) return session.acknowledge(msg.ack); // reliable ack envelope
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

The provider also routes failures from status listeners, awareness events, and
unsubscribe through `onError`. A failing awareness listener does not interrupt
presence removal or destruction. If `onError` itself throws, the provider logs
that and continues.

## ReliableSync (standalone)

```js
import { ReliableSync } from "yrby-client/reliable"; // zero-dep
import * as Y from "yjs";

const rs = new ReliableSync({
  send: (update, id) => { /* frame + transmit */ },
  merge: Y.mergeUpdates,
});

rs.enqueue(update);   // a local document update
rs.acknowledge(id);   // an { ack: id } arrived
rs.resume();          // (re)connected: replay the tail, keep retransmitting
rs.pause();           // dropped: keep the queue, stop retransmitting
```

Pending updates are retained and replayed until the server acknowledges them.
Before each send, the unacknowledged tail is merged into one causally complete
update, so a missed frame does not leave a gap. `enqueue` copies the bytes it
is given, so the caller can reuse its buffer. `pending` returns a snapshot
with copies of each update's bytes. Sorting or editing that snapshot has no
effect on delivery.
Document delivery stays queued and ack-tracked for the lifetime of the session.

## How it fits

The server counterpart — ack *generation*, gap detection, record-before-distribute
— is the `yrby-rails` gem's `Y::ActionCable`. This package
is the client half of the same protocol.

## License

MIT
