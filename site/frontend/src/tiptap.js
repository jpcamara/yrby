// Rich text. The shared state is the Y.XmlFragment that ProseMirror stores its
// document in. Tiptap's Collaboration extension connects the editor to it, and
// CollaborationCursor draws the other carets from awareness.
import { YrbyDocumentElement } from "yrby-client/element"
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Collaboration from "@tiptap/extension-collaboration"
import CollaborationCursor from "@tiptap/extension-collaboration-cursor"
import { enterRoom, roomConsumer, setupRoomPage, user } from "./room.js"

// Returning true from a ProseMirror paste or drop handler marks the event as
// handled. The default insertion is skipped and the file is ignored.
const hasFiles = (transfer) => (transfer?.files?.length || 0) > 0

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

// Tiptap is headless, so the toolbar is the page's own buttons calling editor
// commands. `chain().focus()` keeps the selection through the click, and
// `isActive` sets aria-pressed from the marks at the cursor (the CSS styles
// it). Keyboard shortcuts (⌘B, `# `, `- `) work either way.
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

// The toolbar is the page's markup, outside the editor, so it outlives one
// editor. The buttons call whichever editor is current, and are hidden while
// there's none.
let current = null
const bar = document.getElementById("editor-toolbar")
for (const button of bar.querySelectorAll("[data-cmd]")) {
  // The default mousedown action takes focus from the editor. Preventing it
  // keeps the selection the command should apply to.
  button.addEventListener("mousedown", (e) => e.preventDefault())
  button.addEventListener("click", () => {
    if (current) COMMANDS[button.dataset.cmd]?.(current.chain().focus()).run()
  })
}

function wireToolbar(editor) {
  current = editor
  bar.hidden = false
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

// Create the editor only after the first sync, which is when <yrby-document>
// emits yrby:synced. When it mounts, Tiptap's Collaboration extension adds an
// empty ProseMirror document (one empty paragraph) to the shared Y.Doc. If
// that happens before the server's state arrives, every client inserts its
// own top-level node, and remote content is overwritten as soon as a second
// person edits.
function bind(target, ydoc, provider) {
  const editor = new Editor({
    element: target.querySelector("#editor"),
    // StarterKit only. There's no Image extension, so the schema has no node
    // an upload could turn into. The paste and drop handlers below also block
    // files. Without them, ProseMirror would pass a dropped or pasted file to
    // whatever plugin handles it.
    extensions: [
      StarterKit.configure({ history: false }), // Collaboration has its own undo
      Collaboration.configure({ document: ydoc }),
      CollaborationCursor.configure({ provider, user }),
    ],
    editorProps: {
      handlePaste: (_view, event) => hasFiles(event.clipboardData),
      handleDrop: (_view, event) => hasFiles(event.dataTransfer),
    },
  })
  wireToolbar(editor)
  return {
    editor,
    destroy() {
      current = null
      bar.hidden = true
      editor.destroy()
    },
  }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const binding = bind(target, detail.doc, detail.provider)
  const leave = enterRoom(detail, { editor: binding.editor })
  detail.signal.addEventListener("abort", () => {
    leave()
    binding.destroy()
  }, { once: true })
})
