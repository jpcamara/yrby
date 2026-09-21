# Presence

Presence is who is in the room, where their caret is, and what they have
selected. In Yjs terms that is awareness, and the browser clients own it. The
server doesn't set or hold any presence state. It relays awareness frames
without reading them and stores nothing.

That's why there is no server-side cleanup for presence and no unsubscribe hook
on the channel. There is nothing per connection to clean up.

## Publishing your identity

```js
provider.awareness.setLocalStateField("user", { name: "Ada", color: "#818cf8" })
```

Do this as soon as the provider exists. Peers see you before your editor has
mounted. If your editor binding also sets `user` (Tiptap's
`CollaborationCursor` does), it overwrites the same field when it starts, which
is fine.

Any JSON-serializable value works. This site's spreadsheet demo publishes the
cell you are focused on as a second field. Each browser then draws that cell in
the peer's color, wherever the row sits in that browser's own sort order.

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

`getStates()` is a `Map` from client id to state. Your own entry is in there
too. Filter it out with `awareness.clientID` if you don't want to render
yourself twice.

## Leaving

`yrby-client` sends a best-effort presence-removal frame on disconnect and on
`pagehide`, so a closed tab leaves the room quickly. When a client can't send
that frame (a killed process, a lost network), the client-side awareness
timeout removes it instead.

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

They take the provider, or its `awareness`, directly. `provider.awareness` is a
plain `y-protocols` `Awareness` instance, the same class those bindings already
expect.

## Under AnyCable

Under AnyCable the channel also subscribes an awareness stream with
`whisper: true`. Whispers go from client to client, and only presence uses that
path. Document updates still go through the server, get recorded, and get
acked. Awareness is never recorded or acked.

The browser opts in by using an AnyCable consumer. The provider only whispers
when the subscription has a `whisper` method:

```js
import { createConsumer } from "@anycable/web"
```

Without whispers, every pointer move is a call into your Ruby process. With
them, presence costs the Ruby process nothing. That is worth having in an
authenticated app where the peers trust each other. This site's demos are
public and anonymous, so they turn whispers off and send awareness through the
server's `send` path, which has throttling and validation in front of it. A
whisper skips both, and a room full of strangers shouldn't get that. The
end-to-end test checks that presence still works over `send`.
