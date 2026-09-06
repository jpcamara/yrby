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

This API is unreleased in the published 0.5.0 package. See the
[version note and working example](/docs/getting-started#install).

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
// Append the server-rendered element only after this assignment.
```

Importing the module registers and upgrades existing `<yrby-document>` tags
immediately. When configuring a custom consumer on an already rendered page,
keep the helper's markup inside a `<template>`, configure the consumer and
register the editor listener, then append the template's content. The
[working example](/examples/document) uses that order. Its source is in
[`site/frontend/src/document.js`](https://github.com/jpcamara/yrby/blob/feat/site/site/frontend/src/document.js).


## Document sessions and navigation

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
