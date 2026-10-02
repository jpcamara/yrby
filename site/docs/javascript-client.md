# The JavaScript client

`yrby-client` is the browser half. It has a ready-made Action Cable and AnyCable
provider, a protocol session that doesn't care which transport carries it, and
the reliable-delivery core: an ack-tracked queue, sync since the last ack, and
retransmit and replay on reconnect. It is written in TypeScript, ships its own
types, and comes as both ESM and CommonJS. You can use it from plain JS.

```
npm install yrby-client
```

`yjs` and `y-protocols` are optional peer dependencies. Install them next to it.
If you have an editor binding, you already have both.

## The `<yrby-document>` element

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

`bindYourEditor` stands for your application's editor binding. Its cleanup
must detach Yjs listeners and disable or remove editor controls. It must not
destroy the document or provider, which belong to the session, or disconnect
the shared consumer. The abort signal fires before yrby checks whether a final
update still needs delivery, and you should handle it even if the editor has
already left the DOM.

A document session holds the `Y.Doc`, the provider, and any unacknowledged
edits, and the element attaches an editor to that session. Removing the last
editor clears presence and, if nothing is pending, releases the session. A
session with pending edits keeps delivering them under its original grant
until the server acknowledges them. A rejection stops the retries and keeps
the work in memory for recovery, but it does not count as an acknowledgment.

The element listens for both Turbo and Turbolinks 5 lifecycle events. A cached
preview is inert and creates no document or provider, and the cached markup
holds no CRDT snapshot. When you restore a page from history, the element
reattaches to a pending session if there is one, or loads the saved content
from Rails. A new grant gets its own session, and the previous session's edits
reach it through normal server sync. This all works within one tab and is not
offline storage, so closing or reloading the tab loses unacknowledged edits.

Moving the element within the same turn keeps its editor binding and document.
Remounting it after a delay reloads saved content, and the old `Y.Doc` and undo
stack are gone. Changing the grant, name, or channel aborts the old binding
immediately and acquires a session for the new combination. The old session
keeps any pending work under its original authorization.

The element exposes its current `session`, `doc`, and `provider`. These are
unavailable before the element acquires a session and while it is retargeting,
and reading them never creates a document. `whenSynced` is always a promise,
even before the consumer is initialized, and it resolves after the current
session's first catch-up. If the lease is abandoned, that promise never
resolves. The bubbling `yrby:synced` event fires once per lease and includes
`detail.signal` for cleanup. Being synced doesn't mean the connection is online
or that every edit has been acknowledged. Check `provider.synced` and
`session.hasPending` for those.

Import failures and subscription rejections emit `yrby:error` with
`detail.error`, and a rejection also includes `detail.session` for you to
retry. The element is inert while its session is blocked. After retrying the
session, call `element.activate()` or remount the element to attach again.
`element.destroy()` releases the lease and stops automatic binding until the
element is reinserted, without discarding pending edits.

The `refresh` attribute names a same-origin URL that returns a new grant for
this document as `{ "grant": "..." }`. When the server rejects the
subscription, typically because the grant expired, the session fetches that
URL once and resubscribes with the new grant, keeping its document and
pending edits. See [Grant lifetime and
refresh](https://github.com/jpcamara/yrby#grant-lifetime-and-refresh) in the
main README. The attribute is read when the session is acquired, so changing
it later doesn't rebind the editor.

The default element needs `@rails/actioncable`, `yjs`, and `y-protocols`. All
default elements share one consumer and one import of it while that import is
loading. For AnyCable, assign an ActionCable-compatible consumer before adding
any elements:

```js
import { YrbyDocumentElement } from "yrby-client/element";
import { createConsumer } from "@anycable/web";

YrbyDocumentElement.consumer = createConsumer();
```

Importing the module registers and upgrades existing `<yrby-document>` tags
immediately. When configuring a custom consumer on an already rendered page,
keep the helper's markup inside a `<template>`, configure the consumer and
register the editor listener, then append the template's content. The
[working example](/examples/document) uses that order. Its source is in
[`site/frontend/src/document.js`](https://github.com/jpcamara/yrby/blob/main/site/frontend/src/document.js).


## Document sessions and navigation

A store is scoped to one consumer. Matching `{ channel, grant, name }` tuples
share a document and queue. Grants are compared exactly, never decoded to
infer a common record. Different consumers have separate scopes. Each provider
lifetime adds an opaque `session_id` subscription parameter to isolate its
acknowledgments; this parameter never selects or authorizes a server document.

A headless workflow can hold a lease for as long as it runs:

```js
import { DocumentSessionStore } from "yrby-client";

const store = DocumentSessionStore.for(consumer);
const lease = store.acquire({ grant, name: "body" });
const { session } = lease;
await session.whenSynced;
// Work with session.doc, and hold the lease until the workflow finishes.
lease.release(); // safe to call more than once, and pending work keeps sending
```

Call `lease.setPresence(state)` when an editor gains focus and
`lease.setPresence(null)` when it blurs. All views of one session share one
presence, so the last call wins. An editor binding gets its lease from
`detail.lease` on `yrby:synced`.

`session.state` is `open`, `blocked`, or `closed`, independent of the
provider's transport status. The store emits `change` with the session in
`event.detail`, which you can use to report delivery failures after the page
that made the edits is gone.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});
```

Sessions hold their queues while the consumer is down and deliver them when it
reconnects. A new consumer gets a new store and does not pick up another
consumer's queued work.

A blocked session holds its document and pending edits in memory. `retry()`
reconnects with the session's current grant, which is the original one or the
last one its `refresh` URL returned. `discard()` drops the work. A grant that arrives any other way,
such as a new element attribute, starts a separate session and leaves the
blocked one blocked.

## ActionCableProvider

This is the provider the element uses underneath. Use it directly when you are
wiring things up yourself. With a channel you wrote, the params are whatever
that channel reads: a document key, a room token, anything you like.

```js
const provider = new ActionCableProvider(
  ydoc,
  createConsumer(),
  "DocumentChannel",
  { id: "post/1/body" },
)
```

The constructor takes the document, the consumer, the channel name, and the
channel params. The consumer type is loose, so consumers from
`@rails/actioncable` and `@anycable/web` both work as they are, with no adapter
and no casts. On AnyCable the subscription has a `whisper` method, and the
provider uses it for awareness. Cursor traffic then goes between clients
through the AnyCable server and never reaches your Ruby code. This site's demos
are public, so they skip that and send awareness through the guarded server
path instead. See [Presence](/docs/presence).

## Bind after the first sync

```js
provider.connect()
await provider.whenSynced
// now hand ydoc to the editor binding
```

`whenSynced` resolves once the document has caught up with the server for the
first time. Most editor bindings seed an empty document when they mount. If you
bind before the server's state arrives, each client inserts its own top-level
node, and remote content gets clobbered the moment a second person edits.

If the first catch-up already happened, it resolves immediately, even while the
transport is down. It stays resolved across later reconnects and never fires
again. That makes it the right place to seed starter content: a document
someone emptied stays empty.

## Connection status

There are four states, all reported through one signal:

| Status | Meaning |
|---|---|
| `connecting` | subscription created, transport not up yet |
| `connected` | transport up, exchanging sync steps (UI: "syncing") |
| `synced` | caught up |
| `disconnected` | torn down via `disconnect()` or `destroy()` |

If the transport drops and Action Cable is going to retry, the status is
`connecting`. `disconnected` only means you tore it down yourself.

```js
const off = provider.onStatusChange(({ status }) => {
  statusEl.textContent = status
})
```

`onStatusChange` returns an unsubscribe function. `provider.status` is the
current value, and `provider.synced` is true once the document has caught up.

## Reliable delivery

`provider.hasPending` is true while local updates are still waiting for an ack.
The provider queues the unacked local updates and sends them merged into one
causally complete delta, tagged with the highest sequence number in the batch.
One `{ ack: id }` from the server confirms everything up to that id.

If a resend arrives for an update the server already has, nothing happens,
because applying a CRDT update twice does nothing. On reconnect the queue is
replayed. That replay is also how a causal gap on the server heals: the missing
update is one some client still holds unacked, and that client keeps sending
it.

## Seeding from an HTTP response

`applyRemoteUpdate` applies a bootstrap or restore update without sending it
back to the server as a local edit. Call it once per chunk of state the server
already has, before `connect()`.

```js
provider.applyRemoteUpdate(fromBase64(initialState))
priorUpdates.forEach((u) => provider.applyRemoteUpdate(fromBase64(u)))
provider.connect()
```

If you call `Y.applyUpdate` directly instead, the provider sees it as a local
change and sends it to the server again.

## Teardown

`disconnect()` tears down the subscription and clears this client's presence.
`destroy()` does that and releases the provider.

One thing to know if you reconnect by hand: `disconnect()` removes this
client's awareness entry, and `setLocalStateField` does nothing while the local
state is null. So after a `disconnect()` and a `connect()`, you have to publish
the identity again, or this browser stays invisible to its peers.

```js
provider.onStatusChange(({ status }) => {
  if (status !== "disconnected" && !provider.awareness.getLocalState()) {
    provider.awareness.setLocalState({ user })
  }
})
```

## Bundling: one copy of yjs

Two copies of `yjs` in one bundle is the bug that takes the longest to find.
The provider's `import "yjs"` resolves to one copy and the editor binding uses
another. Yjs's "already imported" guard trips, constructor checks fail, and
y-prosemirror throws "Method unimplemented" when it applies remote updates. The
editor never renders incoming content, and the next local keystroke overwrites
it. None of the symptoms mention module resolution.

Pin the shared packages (`yjs`, `y-protocols`, `lib0`) to one path in your
bundler config. This site's
[`build.mjs`](https://github.com/jpcamara/yrby/blob/main/site/frontend/build.mjs)
does it with a small Bun resolve plugin. In Vite the equivalent is
`resolve.dedupe`, and in webpack it is `resolve.alias`.
