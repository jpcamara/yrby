# Presence

Presence — who is here, where their caret is, what they have selected — is
awareness, and awareness is owned by the browser clients. The server never sets
or holds presence state. It relays awareness frames opaquely and stores nothing.

That is why presence needs no server-side cleanup and why the channel has no
unsubscribe hook: there is nothing per-connection to clean up.

## Publishing your identity

```js
provider.awareness.setLocalStateField("user", { name: "Ada", color: "#818cf8" })
```

Do it as soon as the provider exists. Peers see you before your editor has
mounted, and an editor binding that also sets `user` (Tiptap's
`CollaborationCursor`, for instance) just overwrites the same field when it
starts.

Any JSON-serializable value works. This site's spreadsheet demo publishes the
cell you are focused in as a second field, and each browser draws that cell in
the peer's color wherever the row happens to sit in *its own* sort order.

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

`getStates()` is a `Map` of client id to state. Your own entry is in there;
filter it out with `awareness.clientID` if you don't want to render yourself
twice.

## Leaving

`yrby-client` sends a best-effort presence-removal frame on disconnect and on
`pagehide`, so a closed tab disappears from the room promptly. The client-side
awareness timeout is the fallback for abrupt disconnects — a killed process, a
lost network — where no frame can be sent.

An explicit `disconnect()` clears the local awareness state entirely. If you
reconnect by hand, republish it; see
[The JavaScript client](/docs/javascript-client).

## Editor bindings

Most editor bindings render remote carets for you from the same awareness
object.

| Editor | Extension |
|---|---|
| Tiptap v2 | `CollaborationCursor.configure({ provider, user })` |
| Tiptap v3 / Rhino | `@tiptap/extension-collaboration-caret` |
| CodeMirror 6 | `yCollab(ytext, provider.awareness)` |

They take the provider (or its `awareness`) directly, because
`provider.awareness` is a plain `y-protocols` `Awareness` instance. Nothing
about it is yrby-specific.

## Under AnyCable

Under AnyCable the channel also subscribes an awareness stream with
`whisper: true`, which scopes the client-to-client path to ephemeral presence
rather than the durable document stream. Document updates always go through the
server, are recorded, and are acked. Awareness never is.

The browser has to opt in by using an AnyCable consumer, because the provider
whispers only when the subscription offers `whisper`:

```js
import { createConsumer } from "@anycable/web"
```

That is the difference between presence costing your Ruby process one call per
pointer move and costing it nothing. This site runs that way, and its end-to-end
test counts whispers and sends separately to prove it.
