// Rich text through the flagship stack: a Lexxy editor collaborating via
// lexxy-realtime. The shared state is the Y.XmlFragment Lexical keeps its
// document in; the <lexxy-collaboration> element owns the editor binding, the
// empty-doc bootstrap, and remote carets.
//
// This page uses the npm package's "create the provider yourself" composition:
// room.js builds the yrby-client provider (over @anycable/web, with the room
// bar, presence chips, and full-room notice), and the element receives the doc
// and provider instead of creating its own cable. The provider subscribes to
// NoteChannel with a signed, field-scoped room token the server rendered — the
// token proves this site issued it for this field, and NoteChannel creates the
// Note on subscribe (never on the page GET), which is the whole access model.
import "@37signals/lexxy"
// Lexxy's package exports only expose the JS entry; reach the stylesheet by
// path. Bun bundles it (and lexxy-realtime's caret styles) into public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import "lexxy-realtime/lexxy-realtime.css"
import "lexxy-realtime" // registers <lexxy-collaboration>
import * as Y from "yjs"
import { connectRoom, user } from "./room.js"

const editor = document.getElementById("editor") // <lexxy-editor attachments="false">
const ydoc = new Y.Doc()
const provider = connectRoom(ydoc, editor, {
  channel: "NoteChannel",
  params: { token: editor.dataset.token, field: editor.dataset.field },
})

window.__yrby = { provider, ydoc, user }

// The collaboration element, composed with our doc and provider. It waits for
// the editor to initialize on its own, so appending immediately is fine.
const collab = document.createElement("lexxy-collaboration")
collab.setAttribute("doc-id", editor.dataset.documentKey)
collab.setAttribute("name", user.name)
collab.setAttribute("color", user.color)
collab.doc = ydoc
collab.provider = provider
editor.appendChild(collab)

// The "stored HTML" panel: the materialized note.body column, GET-only, with no
// browser in the render path — the HTML it shows was produced by Y::Lexxy in
// Ruby. It fetches when the panel opens and stays live while it's open: every
// edit (local or remote) schedules a debounced re-fetch, so the panel tracks
// the server-rendered column as you type. The debounce both waits for the
// server to record and materialize the change and keeps continuous typing from
// hammering the endpoint.
const stored = document.querySelector("#stored-html")
const details = document.querySelector("details.stored")
async function loadStored() {
  try {
    const response = await fetch(stored.dataset.url, { headers: { Accept: "application/json" } })
    const { body } = await response.json()
    stored.firstChild.textContent = body || "(empty — type something first)"
  } catch {
    stored.firstChild.textContent = "(could not load)"
  }
}

let refreshTimer = null
function scheduleStoredRefresh() {
  if (!details?.open) return
  clearTimeout(refreshTimer)
  refreshTimer = setTimeout(loadStored, 600)
}
ydoc.on("update", scheduleStoredRefresh)
details?.addEventListener("toggle", () => { if (details.open) loadStored() })

provider.connect() // YrbyProvider-style: no auto-connect
