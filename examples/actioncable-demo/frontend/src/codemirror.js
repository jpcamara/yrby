// Opaque-state demo: a collaborative code editor.
// The shared state is a Y.Text; the official y-codemirror.next binding (yCollab)
// maps it to CodeMirror 6 and renders remote cursors/selections from awareness.
// Same DocumentChannel as every other editor here — yrby has no idea it's
// "code", it just syncs the Y.Text.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { EditorState } from "@codemirror/state"
import { EditorView, basicSetup } from "codemirror"
import { javascript } from "@codemirror/lang-javascript"
import { yCollab } from "y-codemirror.next"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }

const mount = document.getElementById("editor")
const statusEl = document.getElementById("status")
const documentId = mount.dataset.documentId

const ydoc = new Y.Doc()
const ytext = ydoc.getText("code")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.awareness.setLocalStateField("user", user)
window.__yrb = { provider, ydoc, ytext, user }

new EditorView({
  parent: mount,
  state: EditorState.create({
    doc: ytext.toString(),
    extensions: [basicSetup, javascript(), yCollab(ytext, provider.awareness)],
  }),
})

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.dataset.state = status === "synced" ? "connected" : "connecting"
  statusEl.textContent = status === "synced" ? `synced, editing as ${user.name}` : `${status}…`
})
// Seed the starter snippet only on the FIRST catch-up: whenSynced resolves
// with the server's state already applied (no settle timeout needed) and
// doesn't re-fire on reconnects, so a deliberately emptied doc stays empty.
provider.whenSynced.then(() => {
  if (ytext.length === 0) {
    ytext.insert(0, "// Collaborative code — open in two windows.\n" +
      "function greet(name) {\n  return `Hi, ${name}!`\n}\n")
  }
})
provider.connect()
