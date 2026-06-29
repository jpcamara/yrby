// Alternative editor for the demo: a real Lexxy (Lexical) collaborative editor
// driven by `lexxy-realtime`, against the SAME DocumentChannel the Tiptap page
// uses. Nothing on the server changes — both editors speak the yrby
// y-websocket protocol — so this is a drop-in second front end.
//
// lexxy-realtime ships the `<lexxy-collaboration>` custom element and a
// `YrbLiteProvider` (the yrby-client ActionCableProvider). The collaboration
// element owns the editor binding, the empty-doc bootstrap, and remote cursors;
// we just create the doc/provider, mount it inside a `<lexxy-editor>`, and
// connect.
import "@37signals/lexxy"
// Lexxy's package `exports` only expose the JS entry, so reach the stylesheet by
// path. Bun bundles it (and its relative @imports) and emits ../public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { YrbLiteProvider } from "lexxy-realtime" // also registers <lexxy-collaboration>

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]

const editorEl = document.getElementById("editor") // <lexxy-editor>
const statusEl = document.getElementById("status")
const documentId = editorEl.dataset.documentId

const user = {
  name: NAMES[Math.floor(Math.random() * NAMES.length)],
  color: COLORS[Math.floor(Math.random() * COLORS.length)],
}

const ydoc = new Y.Doc()
const consumer = createConsumer()
const provider = new YrbLiteProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
const awareness = provider.awareness // the provider owns presence; read it back

// Exposed for the browser console (parity with the Tiptap page's window.__yrb).
window.__yrb = { provider, ydoc, awareness, user }

const setStatus = (state, text) => {
  statusEl.dataset.state = state
  statusEl.textContent = text
}
setStatus("connecting", `connecting as ${user.name}…`)
provider.onStatusChange(({ status }) => {
  setStatus(status, status === "synced" ? `synced, editing as ${user.name}` : `${status}…`)
})

// Mount the collaboration element once Lexxy has initialized its editor. It
// reads identity from the attributes and uses the doc/awareness/provider we set
// on it directly (rather than creating its own).
function mount() {
  const collab = document.createElement("lexxy-collaboration")
  collab.setAttribute("id", documentId)
  collab.setAttribute("name", user.name)
  collab.setAttribute("color", user.color)
  collab.setAttribute("channel-name", "DocumentChannel")
  collab.setAttribute("channel-params", JSON.stringify({ id: documentId }))
  collab.consumer = consumer
  collab.doc = ydoc
  collab.provider = provider
  editorEl.appendChild(collab)
  provider.connect() // the element wires the binding; we own the connection
}

if (editorEl.editor) {
  mount()
} else {
  editorEl.addEventListener("lexxy:initialize", mount, { once: true })
}
