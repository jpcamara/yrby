// Third editor for the demo: Rhino Editor (KonnorRogers/rhino-editor), the
// ActionText-compatible Tiptap 3 editor, against the SAME DocumentChannel as
// the Tiptap 2 and Lexxy pages. Nothing on the server changes.
//
// This page is the integration a real app would write (see "Using this in
// your own app" in the demo README): the editor's own Collaboration
// extensions, configured before the editor initializes. The only thing you
// would not copy is the import alias. This demo bundles Tiptap 2 (the
// /docs page) and Tiptap 3 (Rhino) side by side, so the v3 extensions are
// installed under an aliased name; in your app they are plain
// "@tiptap/extension-collaboration" and
// "@tiptap/extension-collaboration-caret".
import "rhino-editor"
import "rhino-editor/exports/styles/trix.css"
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import Collaboration from "@tiptap-v3/extension-collaboration"
import CollaborationCaret from "@tiptap-v3/extension-collaboration-caret"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]

const editorEl = document.querySelector("rhino-editor") // has defer-initialize
const statusEl = document.getElementById("status")
const documentId = editorEl.dataset.documentId

const user = {
  name: NAMES[Math.floor(Math.random() * NAMES.length)],
  color: COLORS[Math.floor(Math.random() * COLORS.length)],
}

const ydoc = new Y.Doc()
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.connect()
// Presence is visible to peers as soon as the provider connects, before the
// editor exists (CollaborationCaret sets the same field once it mounts).
provider.awareness.setLocalStateField("user", user)

// Exposed for the browser console and the e2e harness, same shape as the
// other editor pages.
window.__yrb = { provider, ydoc, user, editor: null }

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`

// Collaboration is configured before the editor initializes; the
// defer-initialize attribute holds Rhino back until it's removed.
// Collaboration brings its own undo (a Yjs UndoManager over local edits
// only, so Mod-z never undoes another user's work), and Tiptap's docs say
// to disable the built-in UndoRedo when using it.
//
// The Rhino page binds its own fragment on the shared doc, like the Lexxy
// page binds "root": same document id and channel, its own shape.
editorEl.starterKitOptions = { ...editorEl.starterKitOptions, undoRedo: false }
editorEl.extensions = [
  Collaboration.configure({ fragment: ydoc.getXmlFragment("rhino") }),
  CollaborationCaret.configure({ provider, user }),
]
editorEl.addEventListener(
  "rhino-initialize",
  () => {
    const editor = editorEl.editor
    window.__yrb.editor = editor
    // Console/e2e handles on the same undo the keyboard reaches.
    window.__yrb.undo = () => editor.commands.undo()
    window.__yrb.redo = () => editor.commands.redo()
    statusEl.dataset.state = "connected"
    statusEl.textContent = `synced, editing as ${user.name}`
  },
  { once: true }
)

// Initialize only after the first sync: binding before the server's state
// arrives makes every client seed its own competing top-level node.
provider.whenSynced.then(() => editorEl.removeAttribute("defer-initialize"))
