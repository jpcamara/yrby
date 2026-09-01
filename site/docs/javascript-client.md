# The JavaScript client

`yrby-client` is the browser half: a ready-made Action Cable / AnyCable
provider, a transport-agnostic protocol session, and a reliable-delivery core
(ack-tracked queue, sync-since-last-ack, retransmit and reconnect replay). It is
written in TypeScript with bundled types, ships ESM and CommonJS, and is usable
from plain JS.

```
npm install yrby-client
```

`yjs` and `y-protocols` are optional peer dependencies. Install them alongside
it — you already have them if you have an editor binding.

## ActionCableProvider

```js
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable" // or "@anycable/web"
import { ActionCableProvider } from "yrby-client"

const ydoc = new Y.Doc()
const provider = new ActionCableProvider(
  ydoc,
  createConsumer(),
  "DocumentChannel",
  { id: "post/1/body" },
)
provider.connect()
```

The constructor takes the document, the consumer, the channel name, and the
channel params. The consumer type is deliberately loose, so the consumers from
both `@rails/actioncable` and `@anycable/web` are directly assignable with no
adapter and no casts. On AnyCable the client's subscription exposes `whisper`,
and the provider uses it for awareness — cursor traffic is then relayed between
clients by the AnyCable server and never reaches your Ruby code. This site's own
demos are public, so they opt out of that and route awareness through the guarded
server path instead; see [Presence](/docs/presence).

## Bind after the first sync

```js
provider.connect()
await provider.whenSynced
// now hand ydoc to the editor binding
```

`whenSynced` resolves once the document has first caught up with the server.
Most editor bindings seed an empty document when they mount, so binding before
the server's state arrives makes each client insert its own top-level node and
remote content gets clobbered the moment a second person edits.

It resolves immediately if the first catch-up has already happened, even while
the transport is down, and stays resolved across later reconnects. It does not
re-fire, which is what makes it the right place to seed starter content: a
document someone deliberately emptied stays empty.

## Connection status

Four states, folded into one signal:

| Status | Meaning |
|---|---|
| `connecting` | subscription created, transport not up yet |
| `connected` | transport up, exchanging sync steps (UI: "syncing") |
| `synced` | caught up |
| `disconnected` | torn down via `disconnect()` or `destroy()` |

A dropped transport that Action Cable will retry shows as `connecting`, not
`disconnected`.

```js
const off = provider.onStatusChange(({ status }) => {
  statusEl.textContent = status
})
```

`onStatusChange` returns an unsubscribe function. `provider.status` is the
current value and `provider.synced` is true once caught up.

## Reliable delivery

`provider.hasPending` is true while there are unacknowledged local updates in
flight. The provider keeps the unacked local tail in a queue and sends the
merged tail as a single causally-complete delta, tagged with the highest
sequence in the batch. One `{ ack: id }` from the server cumulatively confirms
everything up to it.

A resend that already landed is a harmless no-op, because applying a CRDT update
twice does nothing. On reconnect the queue is replayed, which is also how a
causal gap on the server heals: the missing dependency is an update some client
still holds unacked.

## Seeding from an HTTP response

`applyRemoteUpdate` applies a bootstrap or restore update without re-sending it
to the server as a local edit. Call it once per chunk of already-durable state,
before `connect()`.

```js
provider.applyRemoteUpdate(fromBase64(initialState))
priorUpdates.forEach((u) => provider.applyRemoteUpdate(fromBase64(u)))
provider.connect()
```

A bare `Y.applyUpdate` would be picked up as a local change and re-broadcast.

## Teardown

`disconnect()` tears down the subscription and clears this client's presence.
`destroy()` does that and releases the provider.

One thing to know about reconnecting by hand: `disconnect()` removes this
client's awareness entry, and `setLocalStateField` is a no-op while the local
state is null. An explicit `connect()` after a `disconnect()` has to republish
the identity, or this browser stays invisible to its peers.

```js
provider.onStatusChange(({ status }) => {
  if (status !== "disconnected" && !provider.awareness.getLocalState()) {
    provider.awareness.setLocalState({ user })
  }
})
```

## Bundling: one copy of yjs

Two copies of `yjs` in one bundle is the failure that costs the most time to
find. The provider's `import "yjs"` resolves to one copy while the editor
binding uses another; Yjs's "already imported" guard trips, constructor checks
fail, and y-prosemirror throws "Method unimplemented" applying remote updates.
The editor never renders incoming content, and the next local keystroke clobbers
it. Nothing about the symptom points at module resolution.

Pin the shared singletons — `yjs`, `y-protocols`, `lib0` — to one canonical path
in your bundler config. This site's
[`build.mjs`](https://github.com/jpcamara/yrby/blob/main/site/frontend/build.mjs)
does it with a small Bun resolve plugin; the same idea is `resolve.dedupe` in
Vite and `resolve.alias` in webpack.
