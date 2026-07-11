import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Collaboration from "@tiptap/extension-collaboration"
import CollaborationCursor from "@tiptap/extension-collaboration-cursor"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]

const element = document.getElementById("editor")
const statusEl = document.getElementById("status")
const documentId = element.dataset.documentId

const user = {
  name: NAMES[Math.floor(Math.random() * NAMES.length)],
  color: COLORS[Math.floor(Math.random() * COLORS.length)],
}

const ydoc = new Y.Doc()
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.connect()

// Exposed for the browser console and the multi-browser test harness. The
// editor is attached once the document has synced (see below).
window.__yrb = { provider, ydoc, user, editor: null }

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`

// Create the editor only after the initial sync. Tiptap's Collaboration
// extension seeds an empty ProseMirror document (a single empty paragraph) into
// the shared Y.Doc when it mounts; doing that before the server's state has
// arrived makes every client insert its own competing top-level node, so remote
// content gets clobbered the moment a second user edits. Mounting post-sync lets
// the existing document bind cleanly and keeps concurrent edits convergent.
function startEditor() {
  const editor = new Editor({
    element,
    extensions: [
      StarterKit.configure({ history: false }), // Collaboration brings its own undo
      Collaboration.configure({ document: ydoc }),
      CollaborationCursor.configure({ provider, user }),
    ],
  })
  window.__yrb.editor = editor
  statusEl.dataset.state = "connected"
  statusEl.textContent = `synced, editing as ${user.name}`
}

provider.whenSynced.then(startEditor)
