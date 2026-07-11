// Third editor for the demo: Rhino Editor (KonnorRogers/rhino-editor), the
// ActionText-compatible Tiptap 3 editor, against the SAME DocumentChannel as
// the Tiptap 2 and Lexxy pages. Nothing on the server changes.
//
// The wiring is deliberately different from the Tiptap page: instead of
// Tiptap's Collaboration extension (which would drag a second @tiptap major
// version into the demo), the raw y-prosemirror plugins go straight into the
// editor via `editor.registerPlugin`. y-prosemirror is plain ProseMirror, so
// the same recipe works for any ProseMirror-based editor regardless of the
// wrapper around it. In your own app, prefer the editor's own Collaboration
// extension — see "Using this in your own app" in the demo README; the raw
// route below is the fallback for editors that don't ship one.
import "rhino-editor"
import "rhino-editor/exports/styles/trix.css"
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { ySyncPlugin, yCursorPlugin, yUndoPlugin, undo, redo } from "y-prosemirror"
import { keymap } from "prosemirror-keymap"

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
// yCursorPlugin reads each peer's `user` awareness field for the caret label.
provider.awareness.setLocalStateField("user", user)

// Exposed for the browser console and the e2e harness, same shape as the
// other editor pages.
window.__yrb = { provider, ydoc, user, editor: null }

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`

// Start the editor only after the initial sync (the same reason as the Tiptap
// page: binding before the server's state arrives makes every client seed its
// own competing top-level node). The `defer-initialize` attribute on the
// element holds Rhino back until we remove it.
function startEditor() {
  editorEl.addEventListener(
    "rhino-initialize",
    () => {
      const editor = editorEl.editor
      // The Rhino page binds its own fragment on the shared doc, like the
      // Lexxy page binds "root": same document id and channel, its own shape.
      //
      // yUndoPlugin MUST be registered last: every registerPlugin call
      // reconfigures the editor state and recreates plugin views, and the
      // undo plugin's view teardown destroys its UndoManager — a later
      // registration would leave an undo manager that never captures.
      editor.registerPlugin(keymap({ "Mod-z": undo, "Mod-y": redo, "Mod-Shift-z": redo }))
      editor.registerPlugin(ySyncPlugin(ydoc.getXmlFragment("rhino")))
      editor.registerPlugin(yCursorPlugin(provider.awareness))
      editor.registerPlugin(yUndoPlugin())
      window.__yrb.editor = editor
      // Console/e2e handles on the Yjs undo manager (same commands the keymap
      // binds).
      window.__yrb.undo = () => undo(editor.state)
      window.__yrb.redo = () => redo(editor.state)
      statusEl.dataset.state = "connected"
      statusEl.textContent = `synced, editing as ${user.name}`
    },
    { once: true }
  )
  // Rhino's own undo/redo (Tiptap 3's UndoRedo) must yield to yUndoPlugin —
  // undoing a remote user's work is the classic collaboration bug.
  editorEl.starterKitOptions = { ...editorEl.starterKitOptions, undoRedo: false }
  editorEl.removeAttribute("defer-initialize")
}

provider.whenSynced.then(startEditor)
