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
// The site's public rooms route awareness through the guarded server path.
const consumer = {
  subscriptions: {
    create(params, callbacks) {
      const subscription = cable.subscriptions.create(params, {
        ...callbacks,
        received(message) {
          if (message?.notice === "document_full") {
            status.textContent = "This shared scratchpad is full. Unsaved changes remain in this tab."
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
    status.textContent = state === "synced" ? "Connected. Ready to edit." : "Reconnecting…"
  })
  status.textContent = "Connected. Ready to edit."
  detail.signal.addEventListener("abort", () => {
    off()
    editor.destroy()
  }, { once: true })
})

document.addEventListener("yrby:error", () => {
  status.textContent = "Unable to connect. Keep this tab open to retain any unsaved work."
})

document.querySelector("#read-document").addEventListener("click", async () => {
  const output = document.querySelector("#stored-document")
  try {
    const response = await fetch("/examples/document/stored", { cache: "no-store" })
    if (!response.ok) throw new Error("Read failed")
    const { body } = await response.json()
    output.textContent = body || "The saved document is empty."
  } catch {
    output.textContent = "Could not read the saved document. Try again."
  }
})

// The element registers on import. Keep server-rendered markup in a template
// until the AnyCable consumer and delegated editor listener are configured.
document.querySelector("#document-container").append(
  document.querySelector("#document-template").content.cloneNode(true),
)
