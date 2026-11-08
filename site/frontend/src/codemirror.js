// Collaborative code. The shared state is a Y.Text, and the y-codemirror.next
// binding connects it to CodeMirror 6 and draws remote cursors and selections
// from awareness. It uses the same channel as the other demos. The server
// doesn't know this is code. It just syncs the Y.Text.
import { YrbyDocumentElement } from "yrby-client/element"
import { EditorState } from "@codemirror/state"
import { EditorView, basicSetup } from "codemirror"
import { javascript } from "@codemirror/lang-javascript"
import { oneDark } from "@codemirror/theme-one-dark"
import { yCollab } from "y-codemirror.next"
import { enterRoom, roomConsumer, setupRoomPage } from "./room.js"

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

function bind(target, ydoc, provider) {
  const ytext = ydoc.getText("code")

  // Add the starter snippet when the document is empty. yrby:synced fires
  // after the server's state is applied and doesn't fire again on reconnect,
  // so a document someone emptied stays empty.
  if (ytext.length === 0) {
    ytext.insert(0, "// Open this room in a second window and edit this code in both.\n" +
      "function greet(name) {\n  return `Hi, ${name}!`\n}\n")
  }

  const view = new EditorView({
    parent: target.querySelector("#editor"),
    state: EditorState.create({
      doc: ytext.toString(),
      extensions: [basicSetup, javascript(), oneDark, yCollab(ytext, provider.awareness)],
    }),
  })
  return { ytext, destroy: () => view.destroy() }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bind(target, detail.doc, detail.provider)
  const leave = enterRoom(detail, { ytext: editor.ytext })
  detail.signal.addEventListener("abort", () => {
    leave()
    editor.destroy()
  }, { once: true })
})
