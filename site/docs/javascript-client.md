# The JavaScript client

`yrby-client` is the browser side of yrby. It includes a ready-made Action Cable
and AnyCable provider, a protocol session that works over any transport, and a
reliable-delivery core. That core keeps an ack-tracked queue, syncs from the
last ack, and retransmits and replays on reconnect. The package is written in
TypeScript, ships its own types, and builds to both ESM and CommonJS. You can
use it from plain JS.

```
npm install yrby-client
```

`yjs` and `y-protocols` are optional peer dependencies, so install them
alongside it. If you already use a Yjs editor binding, you have both.

## The `<yrby-document>` element

yrby-rails' `collaborative_document_tag` renders a `<yrby-document>` element
with a signed grant. It plays the role `<turbo-cable-stream-source>` plays for
`turbo_stream_from`. Import the element once and it connects by itself:

```js
import "yrby-client/element";

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider);
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true });
});
```

`bindYourEditor` stands for your application's editor binding. Its cleanup
should detach Yjs listeners and disable or remove the editor controls. It
shouldn't destroy the document or the provider, because the session manages
those. It also shouldn't disconnect the shared consumer. The abort signal fires
before yrby checks for a final update to deliver. Handle it even if the editor
has already left the DOM.

A document session holds the `Y.Doc`, the provider, and any unacknowledged
edits. The element attaches an editor to that session. When the last editor
detaches, the session clears presence and, if nothing is pending, closes. A
session with pending edits keeps sending them under its original grant until
the server acknowledges them. If the server rejects the subscription, the
session stops retrying and keeps the edits in memory so you can recover them.
Those edits still count as unacknowledged.

The element listens for both Turbo and Turbolinks 5 lifecycle events. A cached
preview is inert. It creates no document or provider, and the cached markup
contains no CRDT snapshot. When you restore a page from history, the element
reattaches to a pending session if one exists. Otherwise it loads the saved
content from Rails. A new grant gets its own session, and the old session's
edits reach it through normal server sync. All of this happens inside one tab.
Nothing is saved for offline use, so closing or reloading the tab loses
unacknowledged edits.

If you remove the element and put it back in the same synchronous block of
code, as a DOM move does, it keeps its editor binding and document. If you
remount it later, it reloads the saved content, and the old `Y.Doc` and undo
stack are gone. Changing the grant, name, or channel aborts the old binding
right away and acquires a session for the new combination. The old session
keeps sending any pending work under its original authorization.

The element exposes its current `session`, `doc`, and `provider`. They're
unavailable before the element acquires a session and while it switches to a
new one. Reading them never creates a document. `whenSynced` is always a
promise, even before the consumer is set up. It resolves after the current
session's first catch-up, and never resolves if the lease is abandoned. The
`yrby:synced` event bubbles, fires once per lease, and includes `detail.signal`
for cleanup. Being synced doesn't mean the connection is online or that every
edit has been acknowledged. Check `provider.synced` and `session.hasPending`
for those.

Import failures and subscription rejections emit `yrby:error` with
`detail.error`. A rejection also includes `detail.session`, which you can
retry. The element does nothing while its session is blocked. After you retry
the session, call `element.activate()` or remount the element to attach again.
`element.destroy()` releases the lease and stops automatic binding until the
element is reinserted. It doesn't discard pending edits.

The `refresh` attribute names a same-origin URL that returns a new grant for
this document as `{ "grant": "..." }`. When the server rejects the
subscription, usually because the grant expired, the session fetches that URL
once and resubscribes with the new grant. It keeps its document and pending
edits. See [Grant lifetime and
refresh](https://github.com/jpcamara/yrby#grant-lifetime-and-refresh) in the
main README. The element reads the attribute when it acquires the session, so
changing it later doesn't rebind the editor.

The default element needs `@rails/actioncable`, `yjs`, and `y-protocols`.
Every default element on the page shares one consumer. For AnyCable, assign an
ActionCable-compatible consumer before adding any elements:

```js
import { YrbyDocumentElement } from "yrby-client/element";
import { createConsumer } from "@anycable/web";

YrbyDocumentElement.consumer = createConsumer();
```

Importing the module registers the element and upgrades any `<yrby-document>`
tags already on the page. If you configure a custom consumer on a page that's
already rendered, put the helper's markup inside a `<template>`. Set the
consumer and register the editor listener first, then append the template's
content. The [working example](/examples/document) does it in that order, and
its source is in
[`site/frontend/src/document.js`](https://github.com/jpcamara/yrby/blob/main/site/frontend/src/document.js).

## Document sessions and navigation

Each consumer has its own session store. Acquisitions with the same
`{ channel, grant, name }` share one document and one queue. The store compares
grants as exact strings and never decodes them to find a shared record. Each
session also adds a random `session_id` subscription parameter so its acks
don't mix with another session's. The server doesn't use it to choose or
authorize a document.

A headless workflow can hold a lease for as long as it runs:

```js
import { DocumentSessionStore } from "yrby-client";

const store = DocumentSessionStore.for(consumer);
const lease = store.acquire({ grant, name: "body" });
const { session } = lease;
await session.whenSynced;
// Work with session.doc, and hold the lease until the workflow finishes.
lease.release(); // safe to call more than once; pending edits keep sending
```

Call `lease.setPresence(state)` when an editor gains focus and
`lease.setPresence(null)` when it blurs. All views of one session share one
presence, so the last call wins. An editor binding gets its lease from
`detail.lease` on `yrby:synced`.

`session.state` is `open`, `blocked`, or `closed`. It's separate from the
provider's connection status. The store emits `change` with the session in
`event.detail`. You can use it to report delivery failures after the page that
made the edits is gone.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});
```

Sessions keep their queues while the consumer is down and send them when it
reconnects. A new consumer gets a new store and doesn't pick up another
consumer's queued work.

A blocked session keeps its document and pending edits in memory. `retry()`
reconnects with the session's current grant, which is either the original one
or the last one its `refresh` URL returned. `discard()` drops the work. A grant
that arrives any other way, such as a new element attribute, starts a separate
session. The blocked one stays blocked.

## ActionCableProvider

The element uses this provider. Use it directly when you wire things up
yourself. With a channel you wrote, the params are whatever that channel reads,
such as a document key or a room token.

```js
const provider = new ActionCableProvider(
  ydoc,
  createConsumer(),
  "DocumentChannel",
  { id: "post/1/body" },
)
```

The constructor takes the document, the consumer, the channel name, and the
channel params. Consumers from `@rails/actioncable` and `@anycable/web` both
work as they are, with no adapter or type casts. On AnyCable the subscription
has a `whisper` method, and the provider uses it for awareness. Cursor traffic
then goes from client to client through the AnyCable server and never reaches
your Ruby code. This site's demos are public, so they turn that off and send
awareness through the server, where it gets throttled and validated. See
[Presence](/docs/presence).

## Bind after the first sync

```js
provider.connect()
await provider.whenSynced
// now hand ydoc to the editor binding
```

`whenSynced` resolves once the document has caught up with the server for the
first time. Most editor bindings seed an empty document when they mount. If you
bind before the server's state arrives, each client inserts its own top-level
node, and remote content gets overwritten as soon as a second person edits.

If the first catch-up has already happened, `whenSynced` resolves right away,
even while the transport is down. It resolves only once and doesn't fire again
on later reconnects. That makes it a good place to add starter content, because
a document someone deliberately emptied won't get refilled.

## Connection status

The provider reports four states through one listener:

| Status | Meaning |
|---|---|
| `connecting` | Subscription created, transport not up yet |
| `connected` | Transport up and exchanging sync steps (show it as "syncing") |
| `synced` | Caught up with the server |
| `disconnected` | You called `disconnect()` or `destroy()` |

When the transport drops and Action Cable is going to retry, the status is
`connecting`. You only see `disconnected` after tearing the provider down
yourself.

```js
const off = provider.onStatusChange(({ status }) => {
  statusEl.textContent = status
})
```

`onStatusChange` returns an unsubscribe function. `provider.status` is the
current value, and `provider.synced` is true once the document has caught up.

## Reliable delivery

`provider.hasPending` is true while local updates are waiting for an ack. The
provider queues unacked local updates and sends them merged into one causally
complete update. It tags that update with the highest sequence number in the
batch. When the server replies `{ ack: id }`, every update up to that id is
confirmed.

If the server receives an update it already has, nothing changes, because
applying a CRDT update twice has no effect. On reconnect the provider replays
the queue. Replay also fills gaps on the server. If the server is missing an
update, some client still has it unacked and keeps resending it.

## Seeding from an HTTP response

`applyRemoteUpdate` applies a bootstrap or restore update without sending it
back to the server as a local edit. Call it once for each piece of state the
server already has, before `connect()`.

```js
provider.applyRemoteUpdate(fromBase64(initialState))
priorUpdates.forEach((u) => provider.applyRemoteUpdate(fromBase64(u)))
provider.connect()
```

If you call `Y.applyUpdate` directly, the provider treats the update as a local
change and sends it to the server again.

## Teardown

`disconnect()` closes the subscription and clears this client's presence.
`destroy()` does the same and then releases the provider.

If you reconnect by hand, you need to publish your identity again.
`disconnect()` removes this client's awareness entry, and `setLocalStateField`
does nothing while the local state is null. After a `disconnect()` and
`connect()`, set the local state again or other clients won't see this browser.

```js
provider.onStatusChange(({ status }) => {
  if (status !== "disconnected" && !provider.awareness.getLocalState()) {
    provider.awareness.setLocalState({ user })
  }
})
```

## Bundling: one copy of yjs

Make sure your bundle contains only one copy of `yjs`. With two copies, the
provider's `import "yjs"` resolves to one and the editor binding uses the
other. Yjs's "already imported" guard trips, constructor checks fail, and
y-prosemirror throws "Method unimplemented" when it applies remote updates. The
editor never shows incoming content, and the next local keystroke overwrites
it. None of these errors mention module resolution, so the cause is hard to
find.

Pin the shared packages (`yjs`, `y-protocols`, `lib0`) to one path in your
bundler config. This site's
[`build.mjs`](https://github.com/jpcamara/yrby/blob/main/site/frontend/build.mjs)
does it with a small Bun resolve plugin. In Vite, use `resolve.dedupe`. In
webpack, use `resolve.alias`.
