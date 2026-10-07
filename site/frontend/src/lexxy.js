// Rich text with a Lexxy editor and lexxy-realtime. The shared state is the
// Y.XmlFragment that Lexical stores its document in. The
// <lexxy-collaboration> element connects the editor to it, sets up an empty
// document, and draws remote carets.
//
// This page creates the provider itself, which the npm package supports.
// room.js builds the yrby-client provider over @anycable/web, along with the
// room bar, presence chips, and full-room notice. The element gets the doc and
// provider from here and doesn't open its own cable.
//
// The provider subscribes to NoteChannel with a signed room token the server
// rendered for this field. NoteChannel accepts any token this site issued for
// the field, and it creates the Note on subscribe, never on the page GET.
import "@37signals/lexxy"
// Lexxy's package exports only include the JS entry, so import the stylesheet
// by path. Bun bundles it with lexxy-realtime's caret styles into
// public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import "lexxy-realtime/lexxy-realtime.css"
import "lexxy-realtime" // registers <lexxy-collaboration>
import * as Y from "yjs"
import { connectRoom, user, wireStoredPanel } from "./room.js"

const editor = document.getElementById("editor") // <lexxy-editor attachments="false">
const ydoc = new Y.Doc()
const provider = connectRoom(ydoc, editor, {
  channel: "NoteChannel",
  params: { token: editor.dataset.token, field: editor.dataset.field },
})

window.__yrby = { provider, ydoc, user }

// The collaboration element, given our doc and provider. It waits for the
// editor to initialize, so it's fine to append it right away.
const collab = document.createElement("lexxy-collaboration")
collab.setAttribute("doc-id", editor.dataset.documentKey)
collab.setAttribute("name", user.name)
collab.setAttribute("color", user.color)
collab.doc = ydoc
collab.provider = provider
editor.appendChild(collab)

// The "Stored HTML" panel shows the note.body column. Y::Lexxy renders that
// HTML in Ruby, with no browser involved. The panel fetches it with a GET and
// refreshes while open, like the other demos.
wireStoredPanel(ydoc)

provider.connect() // the provider doesn't connect on its own
