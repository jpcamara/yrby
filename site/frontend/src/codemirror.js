// Collaborative code. The shared state is a Y.Text, and the y-codemirror.next
// binding connects it to CodeMirror 6 and draws remote cursors and selections
// from awareness. It uses the same channel as the other demos. The server
// doesn't know this is code. It just syncs the Y.Text.
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

// Add the starter snippet only on the first sync. whenSynced resolves after
// the server's state is applied and doesn't fire again on reconnect, so a
// document someone emptied stays empty.
provider.whenSynced.then(() => {
  if (ytext.length === 0) {
    ytext.insert(0, "// Open this room in a second window and edit this code in both.\n" +
      "function greet(name) {\n  return `Hi, ${name}!`\n}\n")
  }
})

wireStoredPanel(ydoc)
provider.connect()
