# Presence

Presence is who's in the room, where their cursor is, and what they've
selected. Yjs calls it awareness. Only browsers set it. The server passes it
along without reading it, and doesn't store it.

That's why the channel needs no presence cleanup or unsubscribe hook. The
server has nothing to clean up.

## Publishing your identity

```js
provider.awareness.setLocalStateField("user", { name: "Ada", color: "#818cf8" })
```

Do this as soon as the provider exists, so others see you before your editor
loads. Some editor bindings, like Tiptap's `CollaborationCursor`, set `user`
too. That's fine. They overwrite the same field when they start.

With `<yrby-document>`, you start with no presence. Set it through the lease.
Call `detail.lease.setPresence({ user: { name, color } })` in your
`yrby:synced` handler, and `setPresence(null)` when the editor loses focus.

Any value that serializes to JSON works. This site's spreadsheet demo also
shares which cell you're in, and every other browser highlights that cell in
your color, even if it sorts the rows differently.

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

`yrby-client` tells the room you've left when it disconnects and when the page
closes, so other people see you go right away. That message can get lost if
the browser crashes or goes offline first. Then the other clients drop you
when your awareness entry times out.

Calling `disconnect()` clears the local awareness state. If you reconnect by
hand, publish your identity again. See
[The JavaScript client](/docs/javascript-client).

## Editor bindings

Most editor bindings draw other people's cursors for you, from the same
awareness object.

| Editor | Extension |
|---|---|
| Tiptap v2 | `CollaborationCursor.configure({ provider, user })` |
| Tiptap v3 / Rhino | `@tiptap/extension-collaboration-caret` |
| CodeMirror 6 | `yCollab(ytext, provider.awareness)` |

You pass them the provider or its `awareness`. `provider.awareness` is a plain
`y-protocols` `Awareness` instance, which is the class those bindings expect.

## Under AnyCable

On AnyCable, the channel also opens a presence stream with `whisper: true`. A
whisper goes from one browser to the others without calling your Ruby code.
Only presence uses it. Document edits still go through the server, which
saves and confirms them.

To use whispers, create the consumer with `@anycable/web`. The provider
whispers whenever the subscription supports it:

```js
import { createConsumer } from "@anycable/web"
```

Without whispers, every cursor move is a call into Ruby. With them, presence
never reaches Ruby. That suits a logged-in app where users trust each other.

This site's demos are public and anonymous, so they turn whispers off. Presence
goes through the server like everything else, where it's rate-limited and
checked. Whispers would skip those checks, which isn't safe in a room full of
strangers. The end-to-end test checks that presence still works this way.
