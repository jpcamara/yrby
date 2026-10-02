// Rich text. The shared state is the Y.XmlFragment that ProseMirror keeps its
// document in; Tiptap's own Collaboration extension does the binding, and
// CollaborationCursor renders the other carets from awareness.
import * as Y from "yjs"
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Collaboration from "@tiptap/extension-collaboration"
import CollaborationCursor from "@tiptap/extension-collaboration-cursor"
import { connectRoom, user, wireStoredPanel } from "./room.js"

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
// Tiptap is headless: the toolbar is the page's own buttons, wired to editor
// commands. `chain().focus()` keeps the selection through the click, and
// `isActive` reflects the cursor's marks back as aria-pressed (which the CSS
// styles). Keyboard shortcuts (⌘B, `# `, `- `) work regardless.
const COMMANDS = {
  bold: (c) => c.toggleBold(),
  italic: (c) => c.toggleItalic(),
  strike: (c) => c.toggleStrike(),
  code: (c) => c.toggleCode(),
  h1: (c) => c.toggleHeading({ level: 1 }),
  h2: (c) => c.toggleHeading({ level: 2 }),
  bulletList: (c) => c.toggleBulletList(),
  orderedList: (c) => c.toggleOrderedList(),
  blockquote: (c) => c.toggleBlockquote(),
  codeBlock: (c) => c.toggleCodeBlock(),
}
const ACTIVE_CHECKS = {
  bold: "bold", italic: "italic", strike: "strike", code: "code",
  bulletList: "bulletList", orderedList: "orderedList",
  blockquote: "blockquote", codeBlock: "codeBlock",
}

function wireToolbar(editor) {
  const bar = document.getElementById("editor-toolbar")
  if (!bar) return
  bar.hidden = false
  for (const button of bar.querySelectorAll("[data-cmd]")) {
    // mousedown's default is what steals focus from the editor; preventing it
    // keeps the selection the command should apply to.
    button.addEventListener("mousedown", (e) => e.preventDefault())
    button.addEventListener("click", () => {
      COMMANDS[button.dataset.cmd]?.(editor.chain().focus()).run()
    })
  }
  const reflect = () => {
    for (const button of bar.querySelectorAll("[data-cmd]")) {
      const cmd = button.dataset.cmd
      const active = cmd === "h1" || cmd === "h2"
        ? editor.isActive("heading", { level: cmd === "h1" ? 1 : 2 })
        : editor.isActive(ACTIVE_CHECKS[cmd])
      button.setAttribute("aria-pressed", String(active))
    }
  }
  editor.on("selectionUpdate", reflect)
  editor.on("transaction", reflect)
}

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
  wireToolbar(window.__yrby.editor)
})

wireStoredPanel(ydoc)
provider.connect()
