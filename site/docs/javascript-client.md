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

`collaborative_document_tag` renders an element that connects on its own.
Importing the element registers it, and after that there is no connection code
to write per feature:

```js
import "yrby-client/element"

document.querySelector("yrby-document").addEventListener("yrby:synced", ({ target }) => {
  bindYourEditor(target.doc) // fires after the first catch-up
})
```

The element subscribes to the gem's `Y::DocumentChannel` with the grant from
the tag. Set a `channel` attribute to use a different channel name. It keeps
its `Y.Doc` across DOM moves and Turbo restores, and it exposes `doc`,
`provider`, and `whenSynced`. All the elements on a page share one consumer,
which comes from `@rails/actioncable` by default. On AnyCable, assign
`YrbyDocumentElement.consumer = createCable()` once, before the elements
connect.

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
