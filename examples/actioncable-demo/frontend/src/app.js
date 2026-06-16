import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ReliableActionCableProvider } from "../provider/reliable_actioncable_provider.mjs"
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

// The reliable provider is the standard @y-rb/actioncable WebsocketProvider
// (wire-compatible with yrb-lite's server: the `{ update: ... }` envelope, one
// protocol message per frame) augmented with ack-based delivery. It tags each
// batch with an id, retains the unacked tail, and retransmits until the server
// acks -- so an edit can't be silently lost on a flaky connection. Pass
// `reliable: false` to fall back to the stock provider behavior.
const ydoc = new Y.Doc()
const consumer = createConsumer()
const provider = new ReliableActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`
const poll = setInterval(() => {
  if (provider.synced) {
    statusEl.dataset.state = "connected"
    statusEl.textContent = `synced, editing as ${user.name}`
    clearInterval(poll)
  }
}, 150)

const editor = new Editor({
  element,
  extensions: [
    StarterKit.configure({ history: false }), // Collaboration brings its own undo
    Collaboration.configure({ document: ydoc }),
    CollaborationCursor.configure({ provider, user }),
  ],
})

// Exposed for the browser console and the multi-browser test harness.
window.__yrb = { provider, ydoc, editor, user }
