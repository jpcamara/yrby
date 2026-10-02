# Presence

Presence is who is in the room, where their caret is, and what they have
selected. Yjs calls this awareness, and only the browsers set it. The server
doesn't set or hold any presence state. It relays awareness frames without
reading them and stores nothing.

So the channel has no presence cleanup and no unsubscribe hook. The server
keeps nothing per connection that would need cleaning up.

## Publishing your identity

```js
provider.awareness.setLocalStateField("user", { name: "Ada", color: "#818cf8" })
```

Do this as soon as the provider exists, so peers see you before your editor
mounts. Some editor bindings also set `user`, such as Tiptap's
`CollaborationCursor`. That binding overwrites the same field when it starts,
and that's fine.

With `<yrby-document>`, the session starts with no local presence. Set it
through the lease. Call `detail.lease.setPresence({ user: { name, color } })`
from your `yrby:synced` handler, and call `setPresence(null)` when the editor
blurs.

Any JSON-serializable value works. This site's spreadsheet demo also publishes
the cell you're focused on. Each browser draws that cell in the peer's color,
even when the two browsers sort the rows differently.

```js
input.addEventListener("focus", () => provider.awareness.setLocalStateField("cell", cellId))
input.addEventListener("blur", () => provider.awareness.setLocalStateField("cell", null))
```

## Reading the room

```js
provider.awareness.on("update", () => {
  const peers = [...provider.awareness.getStates().entries()]
    .filter(([clientId]) => clientId !== provider.awareness.clientID)
    .map(([, state]) => state.user)
    .filter(Boolean)
  render(peers)
})
```

`getStates()` is a `Map` from client id to state, and it includes your own
entry. Filter it out with `awareness.clientID` so you don't render yourself
twice.

## Leaving

`yrby-client` sends a presence-removal frame on disconnect and on `pagehide`,
so a closed tab leaves the room quickly. Delivery isn't guaranteed. If the
browser crashes or loses its network before the frame goes out, other clients
remove the entry when its awareness timeout expires.

Calling `disconnect()` clears the local awareness state. If you reconnect by
hand, publish your identity again. See
[The JavaScript client](/docs/javascript-client).

## Editor bindings

Most editor bindings render remote carets for you from the same awareness
object.

| Editor | Extension |
|---|---|
| Tiptap v2 | `CollaborationCursor.configure({ provider, user })` |
| Tiptap v3 / Rhino | `@tiptap/extension-collaboration-caret` |
| CodeMirror 6 | `yCollab(ytext, provider.awareness)` |

You pass them the provider or its `awareness`. `provider.awareness` is a plain
`y-protocols` `Awareness` instance, which is the class those bindings expect.

## Under AnyCable

Under AnyCable the channel also subscribes to an awareness stream with
`whisper: true`. A whisper goes from one client to the others without calling
your Ruby code, and only presence uses it. Document updates still go through
the server, where they're recorded and acked. Awareness is never recorded or
acked.

The browser opts in by using an AnyCable consumer. The provider whispers only
when the subscription has a `whisper` method:

```js
import { createConsumer } from "@anycable/web"
```

Without whispers, every pointer move calls into your Ruby process. With them,
presence doesn't touch Ruby at all. That's a good fit for an authenticated app
where users trust each other.

This site's demos are public and anonymous, so they turn whispers off. Awareness
goes through the channel's `send` path instead, where the server throttles and
validates every frame. A whisper would skip those checks, which isn't safe in a
room full of strangers. The end-to-end test confirms that presence still works
over `send`.
