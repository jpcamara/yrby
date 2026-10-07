import { createConsumer } from "@anycable/web"
import { YrbyDocumentElement } from "yrby-client/element"
import { EditorState } from "@codemirror/state"
import { EditorView, basicSetup } from "codemirror"
import { oneDark } from "@codemirror/theme-one-dark"
import { yCollab } from "y-codemirror.next"

const status = document.querySelector("#document-status")
const cableUrl = new URL(document.querySelector('meta[name="action-cable-url"]').content, location.href)
cableUrl.protocol = location.protocol === "https:" ? "wss:" : "ws:"
const cable = createConsumer(cableUrl.href)
// These rooms are public, so awareness goes through the server's checked
// receive path. Clearing `whisper` makes the provider send it that way.
const consumer = {
  subscriptions: {
    create(params, callbacks) {
      const subscription = cable.subscriptions.create(params, {
        ...callbacks,
        received(message) {
          if (message?.notice === "document_full") {
            status.textContent = "This shared scratchpad is full, so new edits won't be saved. Anything typed since then is only in this tab."
          } else {
            callbacks.received(message)
          }
        },
      })
      subscription.whisper = undefined
      return subscription
    },
  },
}
YrbyDocumentElement.consumer = consumer

document.addEventListener("yrby:synced", ({ target, detail }) => {
  if (target.id !== "document-editor") return
  const editor = new EditorView({
    parent: target.querySelector("[data-editor-mount]"),
    state: EditorState.create({
      doc: detail.doc.getText("content").toString(),
      extensions: [basicSetup, oneDark, EditorView.lineWrapping,
        EditorView.theme({ ".cm-content": { minHeight: "140px" } }),
        EditorView.contentAttributes.of({ "aria-label": "Shared document" }),
        yCollab(detail.doc.getText("content"), detail.provider.awareness)],
    }),
  })
  const off = detail.provider.onStatusChange(({ status: state }) => {
    status.textContent = state === "synced" ? "Synced. Ready to edit." : "Reconnecting…"
  })
  status.textContent = "Synced. Ready to edit."
  detail.signal.addEventListener("abort", () => {
    off()
    editor.destroy()
  }, { once: true })
})

document.addEventListener("yrby:error", () => {
  status.textContent = "Couldn't connect. Keep this tab open so your unsaved edits aren't lost."
})

document.querySelector("#read-document").addEventListener("click", async () => {
  const output = document.querySelector("#stored-document")
  try {
    const response = await fetch("/examples/document/stored", { cache: "no-store" })
    if (!response.ok) throw new Error("Read failed")
    const { body } = await response.json()
    output.textContent = body || "The saved document is empty."
  } catch {
    output.textContent = "Couldn't read the saved document. Try again."
  }
})

// The element registers itself on import. The markup stays in a template until
// the AnyCable consumer and the editor listener above are set up.
document.querySelector("#document-container").append(
  document.querySelector("#document-template").content.cloneNode(true),
)
