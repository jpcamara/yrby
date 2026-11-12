# The JavaScript client

`yrby-client` is the browser half of yrby. It has a provider for Action Cable
and AnyCable, plus the pieces that provider is built from: a protocol session
that works over any transport, and a queue that resends edits until the server
confirms them. It's written in TypeScript, includes its own types, and works from
plain JavaScript as ESM or CommonJS.

```
npm install yrby-client
```

`yjs` and `y-protocols` are optional peer dependencies, so install them
alongside it. If you already use a Yjs editor binding, you have both.

## The `<yrby-document>` element

yrby-rails' `collaborative_document_tag` renders a `<yrby-document>` element
with a signed token in it, much like `turbo_stream_from` renders a
`<turbo-cable-stream-source>`. Import the element once and it connects by
itself:

```js
import "yrby-client/element";

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bindYourEditor(target, detail.doc, detail.provider);
  detail.signal.addEventListener("abort", () => editor.destroy(), { once: true });
});
```

`bindYourEditor` stands for however you attach your editor. When the signal
aborts, remove the Yjs listeners and disable or remove the editor. Don't
destroy the Yjs document, the provider, or the shared consumer, because yrby
manages those. The signal fires before yrby sends any final update. Handle it even if the
editor is already gone from the page.

Behind each element is a document session. It holds the `Y.Doc`, the provider,
and any edits the server hasn't confirmed. When the last editor detaches, the
session clears your presence, and it closes if nothing is waiting to be sent.
If edits are still waiting, it keeps sending them with the original token
until the server confirms them. If the server rejects the subscription, the
session stops and keeps the unsent edits in memory so you can recover them.

The element works with Turbo and Turbolinks 5. A cached preview doesn't create
a Yjs document or connect. When you go back to a page, the element picks up its
old session if that session still has unsent edits. Otherwise it loads the
saved content from Rails. If the page renders a new token, the element gets a
new session, and the old session's edits reach it through the server like
anyone else's. This all happens within one tab. Nothing is stored for offline
use, so closing or reloading the tab loses edits the server hasn't confirmed.

Moving the element in the DOM keeps its editor and Yjs document, as long as you
remove and reinsert it in the same synchronous block of code. If you put it
back later, it reloads the saved content, and the old `Y.Doc` and undo history
are gone. Changing the token, name, or channel tears down the old editor right
away and connects to the Yjs document the new token points at. The old
session still finishes sending its unsent edits with its original token.

The element exposes its current `session`, `doc`, and `provider`. They're
undefined until it connects and while it switches Yjs documents, and reading them
never creates one. `whenSynced` is always a promise, even before the consumer
is set up. It resolves when the Yjs document first catches up with the server, and
never resolves if the element gives up on it. The `yrby:synced`
event bubbles, fires once each time the element connects to a Yjs document, and
includes `detail.signal` for cleanup. Synced doesn't mean the connection is up
right now, or that every edit is confirmed. Check `provider.synced` and
`session.hasPending` for those.

`element.current` is the detail of the last `yrby:synced` event,
`{ session, doc, provider, lease, signal }`, while that lease is still bound.
It's undefined before the first sync, while the element switches Yjs
documents or its page is cached, while its session is blocked, and from the
moment the lease aborts. It's already set when `yrby:synced` fires. Code that
loads after the event has fired reads it instead of waiting for an event that
won't come again:

```js
function attach(element, bind) {
  if (element.current) bind(element.current)
  element.addEventListener("yrby:synced", ({ detail }) => bind(detail))
}
```

If the import fails or the server rejects the subscription, the element fires
`yrby:error` with `detail.error`. A rejection also includes `detail.session`,
so you can retry it. While the session is blocked, the element does nothing.
After you retry the session, call `element.retry()` to attach again.

`element.retry()` makes the element get its Yjs document again after its
session was blocked or discarded. It does nothing while the element is bound
to a session, or still connecting to one. It doesn't change whether the page
is live, so on a cached page the element connects when Turbo shows the page
again. You can call it from a lease's abort handler, or right after
`session.discard()`. A discarded session has left the store, so the element
gets a new session with a new `Y.Doc` loaded from the server. That's how an
editor binding replaces a Yjs document it can't trust anymore:

```js
const { session } = element.current
session.discard() // aborts every lease, so bindings clean up now
element.retry()   // yrby:synced fires again with a new session
```

`element.destroy()` disconnects the element until it's put back on the page.
It doesn't throw away unsent edits.

The `refresh` attribute is a same-origin URL that returns a new token for this
record attribute as `{ "grant": "..." }`. When the server rejects the subscription,
usually because the token expired, the session fetches that URL once and
subscribes again with the new token. It keeps its Yjs document and unsent edits.
See [Grant lifetime and
refresh](https://github.com/jpcamara/yrby#grant-lifetime-and-refresh) in the
main README. The element reads this attribute when it connects, so changing it
later has no effect on the current editor.

By default the element needs `@rails/actioncable`, `yjs`, and `y-protocols`,
and every element on the page shares one consumer. For AnyCable, set
`YrbyDocumentElement.consumer` before any element needs a consumer. It takes a
consumer, a promise of one, or a function that returns either:

```js
import { YrbyDocumentElement } from "yrby-client/element";
import { createConsumer } from "@anycable/web";

YrbyDocumentElement.consumer = () => createConsumer();
```

The element calls the function the first time it needs a consumer, not when
you assign it, and every element reuses the result. If the function throws or
its promise rejects, the element fires `yrby:error`, and the next attempt
(`retry()` or the next page render) calls the function again. Assigning a
different value replaces the result.

Importing the module registers the element, and any `<yrby-document>` tags
already on the page start connecting. Each one asks for its consumer after the
current script finishes, so set the consumer in the same script that imports
the element, as above. If your consumer setup runs later, in another script,
put the tag inside a `<template>`. Set the consumer and add your `yrby:synced`
listener first, then insert the template's content. The
[working example](/examples/document) does it in that order, and its source is
in
[`site/frontend/src/document.js`](https://github.com/jpcamara/yrby/blob/main/site/frontend/src/document.js).

## Document sessions and navigation

Each consumer has its own session store. Elements with the same channel,
token, and name share one Yjs document and one queue of unsent edits. The store
compares tokens as plain strings and never decodes them. Each session adds a
random `session_id` to its subscription, so its acks don't get mixed up with
another session's. The server doesn't use it to pick a Yjs document or to
authorize anything.

Code without an editor can hold a lease for as long as it needs the Yjs
document:

```js
import { DocumentSessionStore } from "yrby-client";

const store = DocumentSessionStore.for(consumer);
const lease = store.acquire({ grant, name: "body" });
const { session } = lease;
await session.whenSynced;
// Work with session.doc, and hold the lease until the workflow finishes.
lease.release(); // safe to call more than once; pending edits keep sending
```

Call `lease.setPresence(state)` when an editor gets focus and
`lease.setPresence(null)` when it loses it. Every view of a session shares one
presence, so the last call wins. Your editor code gets its lease from
`detail.lease` on `yrby:synced`.

`session.state` is `open`, `blocked`, or `closed`. It doesn't tell you
whether the provider is connected. The store fires `change` with the session
in `event.detail`. Use it to report edits that couldn't be delivered, even
after the page that made them is gone.

```js
store.addEventListener("change", ({ detail: session }) => {
  if (session.state === "blocked") reportDeliveryFailure(session.error, session);
});
```

Sessions keep their queues while the consumer is down and send them when it
reconnects. A new consumer gets a new store and doesn't pick up another
consumer's queued work.

A blocked session keeps its Yjs document and unsent edits in memory. `retry()`
reconnects with its current token, which is the original or the last one its
`refresh` URL returned. `discard()` throws the edits away. A token that
arrives any other way, such as a new element attribute, starts a separate
session and leaves the blocked one alone.

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

The constructor takes the Yjs document, the consumer, the channel name, and the
channel params. Consumers from `@rails/actioncable` and `@anycable/web` both
work without adapters or type casts. On AnyCable, the provider sends presence
as whispers, so cursor updates go straight between browsers through AnyCable
and never reach your Ruby code. This site's demos are public, so they turn
that off and send presence through the server, where it's rate-limited and
checked. See [Presence](/docs/presence).

## Bind after the first sync

```js
provider.connect()
await provider.whenSynced
// now hand ydoc to the editor binding
```

`whenSynced` resolves when the Yjs document first catches up with the server.
Most editor bindings add an empty paragraph when they start. If you attach the
editor before the server's copy arrives, every client adds its own empty
paragraph to the text everyone is editing.

If that already happened, `whenSynced` resolves right away, even while
disconnected. It resolves once, and later reconnects don't trigger it again.
That makes it a good place to add starter content, since it won't refill an
editor someone emptied on purpose.

## Connection status

The provider reports four states through one listener:

| Status | Meaning |
|---|---|
| `connecting` | Subscription created, transport not up yet |
| `connected` | Transport up and exchanging sync steps (show it as "syncing") |
| `synced` | Caught up with the server |
| `disconnected` | You called `disconnect()` or `destroy()` |

When the connection drops and Action Cable retries, the status goes back to
`connecting`. You only see `disconnected` after you disconnect or destroy the
provider yourself.

```js
const off = provider.onStatusChange(({ status }) => {
  statusEl.textContent = status
})
```

`onStatusChange` returns an unsubscribe function. `provider.status` is the
current value, and `provider.synced` is true once the Yjs document has caught up.

## Reliable delivery

`provider.hasPending` is true while local edits are waiting to be confirmed.
The provider merges everything in its queue into one update and tags it with
the highest sequence number in the batch. When the server replies
`{ ack: id }`, every edit up to that id is confirmed.

If the server gets an update it already has, nothing changes. On reconnect,
the provider sends its whole queue again. That's also how the server fills
gaps. If it's missing an update, the client that made it still hasn't had it
confirmed, so that client keeps resending it.

## Seeding from an HTTP response

`applyRemoteUpdate` loads state into the Yjs document without sending it back to
the server as a new edit. Call it for each piece of state the server already
has, before `connect()`.

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

If you reconnect by hand, set your presence again. `disconnect()` clears it,
and `setLocalStateField` does nothing while it's null. So after `disconnect()`
and `connect()`, call `setLocalState` again, or other people won't see you.

```js
provider.onStatusChange(({ status }) => {
  if (status !== "disconnected" && !provider.awareness.getLocalState()) {
    provider.awareness.setLocalState({ user })
  }
})
```

## Bundling: one copy of yjs

Make sure your bundle has only one copy of `yjs`. With two, the provider and
the editor binding each get their own. Yjs warns that it was already imported,
`instanceof` checks fail, and y-prosemirror throws "Method unimplemented" on
remote updates. The editor never shows other people's changes, and your next
keystroke overwrites them. None of these errors point at the duplicate
import, so it's hard to track down.

Pin the shared packages (`yjs`, `y-protocols`, `lib0`) to one path in your
bundler config. This site's
[`build.mjs`](https://github.com/jpcamara/yrby/blob/main/site/frontend/build.mjs)
does it with a small Bun resolve plugin. In Vite, use `resolve.dedupe`. In
webpack, use `resolve.alias`.
