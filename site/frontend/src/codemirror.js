// Collaborative code. The shared state is a Y.Text; the official
// y-codemirror.next binding maps it to CodeMirror 6 and renders remote
// cursors and selections from awareness. Same channel as every other demo —
// the server has no idea this is code, it syncs the Y.Text.
import * as Y from "yjs"
import { EditorState } from "@codemirror/state"
import { EditorView, basicSetup } from "codemirror"
import { javascript } from "@codemirror/lang-javascript"
import { oneDark } from "@codemirror/theme-one-dark"
import { yCollab } from "y-codemirror.next"
import { connectRoom, user, wireStoredPanel } from "./room.js"

const mount = document.getElementById("editor")
const ydoc = new Y.Doc()
const ytext = ydoc.getText("code")
const provider = connectRoom(ydoc, mount)

window.__yrby = { provider, ydoc, ytext, user }

new EditorView({
  parent: mount,
  state: EditorState.create({
    doc: ytext.toString(),
    extensions: [basicSetup, javascript(), oneDark, yCollab(ytext, provider.awareness)],
  }),
})

// Seed the starter snippet only on the FIRST catch-up: whenSynced resolves with
// the server's state already applied, and doesn't re-fire on reconnects, so a
// deliberately emptied document stays empty.
provider.whenSynced.then(() => {
  if (ytext.length === 0) {
    ytext.insert(0, "// Collaborative code — open this room in a second window.\n" +
      "function greet(name) {\n  return `Hi, ${name}!`\n}\n")
  }
})

wireStoredPanel(ydoc)
provider.connect()
