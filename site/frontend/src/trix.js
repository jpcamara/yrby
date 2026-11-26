// Rich text in Trix. The shared state is one Y.Text in the shape of Trix's
// own document model, and the y-trix binding keeps the editor and the Y.Text
// in step in both directions. It draws the other carets from awareness and
// puts a Y.UndoManager behind Trix's undo, so undo only takes back this
// browser's changes.
import Trix from "trix"
import { YrbyDocumentElement } from "yrby-client/element"
import { TrixBinding } from "y-trix"
import { enterRoom, roomConsumer, setupRoomPage } from "./room.js"

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

// The toolbar is the page's markup (see _trix.html.erb), so it outlives one
// editor. It's hidden while there's none.
const bar = document.getElementById("trix-toolbar")

// The <trix-editor> is created after the first sync, which is when
// <yrby-document> emits yrby:synced, so nobody types into an editor that
// isn't bound yet. Trix sets the element up asynchronously and fires
// trix-initialize when it's ready, and the binding needs a ready editor.
function bind(target, ydoc, provider) {
  const element = document.createElement("trix-editor")
  element.setAttribute("toolbar", bar.id)
  element.setAttribute("aria-label", "Shared document")
  // The site takes no uploads, so the binding runs with attachments off (see
  // below): it refuses files, and it shows an attachment that is in the
  // Y.Text all the same (a client that talks the protocol directly can put
  // one there) as a placeholder character and not as an image or a card.
  // This listener is the second lock on the same door: should Trix ever end
  // up with an attachment in this editor, it is taken out again.
  element.addEventListener("trix-attachment-add", ({ attachment }) => attachment.remove())

  let binding = null
  let gone = false
  element.addEventListener("trix-initialize", () => {
    if (gone) return
    binding = new TrixBinding(ydoc.getText("trix"), element, provider.awareness, { Trix, attachments: false })
    bar.hidden = false
  }, { once: true })
  target.querySelector("#editor").append(element)

  return {
    element,
    destroy() {
      gone = true
      bar.hidden = true
      binding?.destroy()
      element.remove()
    },
  }
}

document.addEventListener("yrby:synced", ({ target, detail }) => {
  const editor = bind(target, detail.doc, detail.provider)
  const leave = enterRoom(detail, { ytext: detail.doc.getText("trix"), element: editor.element })
  detail.signal.addEventListener("abort", () => {
    leave()
    editor.destroy()
  }, { once: true })
})
