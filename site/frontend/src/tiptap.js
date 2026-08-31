// Rich text. The shared state is the Y.XmlFragment that ProseMirror keeps its
// document in; Tiptap's own Collaboration extension does the binding, and
// CollaborationCursor renders the other carets from awareness.
import * as Y from "yjs"
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Collaboration from "@tiptap/extension-collaboration"
import CollaborationCursor from "@tiptap/extension-collaboration-cursor"
import { connectRoom, user } from "./room.js"

// Returning true from a ProseMirror paste/drop handler means "handled" — the
// default insertion is skipped and the file goes nowhere.
const hasFiles = (transfer) => (transfer?.files?.length || 0) > 0

const element = document.getElementById("editor")
const ydoc = new Y.Doc()
const provider = connectRoom(ydoc, element)

// Exposed for the browser console and the e2e harness.
window.__yrby = { provider, ydoc, user, editor: null }

// Create the editor only after the initial sync. Tiptap's Collaboration
// extension seeds an empty ProseMirror document (a single empty paragraph) into
// the shared Y.Doc when it mounts; doing that before the server's state has
// arrived makes every client insert its own competing top-level node, so remote
// content gets clobbered the moment a second user edits.
provider.whenSynced.then(() => {
  window.__yrby.editor = new Editor({
    element,
    // StarterKit only: no Image extension, so the schema has no node an upload
    // could become. The handlers below are the second half of the site's
    // no-uploads policy — ProseMirror would otherwise be free to route a
    // dropped or pasted file to whatever plugin claims it.
    extensions: [
      StarterKit.configure({ history: false }), // Collaboration brings its own undo
      Collaboration.configure({ document: ydoc }),
      CollaborationCursor.configure({ provider, user }),
    ],
    editorProps: {
      handlePaste: (_view, event) => hasFiles(event.clipboardData),
      handleDrop: (_view, event) => hasFiles(event.dataTransfer),
    },
  })
})

provider.connect()
