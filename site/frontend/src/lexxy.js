// The Lexxy demo. The view renders form.collaborative_rich_textarea :body,
// and importing lexxy-realtime registers the elements it renders:
// <yrby-document> subscribes to LexxyChannel with the room's grant and holds
// the Yjs document, and <lexxy-collaboration> binds the editor to it once it
// syncs. The rest comes from room.js, which every demo shares: the AnyCable
// consumer, the cursor name and color, the room bar, the status line, and the
// stored HTML panel.
// begin source excerpt
import "@37signals/lexxy"
import "lexxy-realtime"
// end source excerpt
// Lexxy's package exports only include the JS entry, so import the stylesheet
// by path. Bun bundles it with lexxy-realtime's caret styles into
// public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import "lexxy-realtime/lexxy-realtime.css"
import { setConsumer } from "lexxy-realtime"
import { roomConsumer, setupRoomPage, showRoomState, user, wireStoredPanel } from "./room.js"

setConsumer(() => roomConsumer())
setupRoomPage()

const element = document.querySelector("yrby-document")
const collab = element.querySelector("lexxy-collaboration")
collab.setAttribute("name", user.name)
collab.setAttribute("color", user.color)

element.addEventListener("yrby:synced", ({ detail }) => {
  window.__yrby = { provider: detail.provider, ydoc: detail.doc, user }
  const stopRoomState = showRoomState(detail.provider)
  const stopStoredPanel = wireStoredPanel(detail.doc)
  detail.signal.addEventListener("abort", () => {
    stopRoomState()
    stopStoredPanel()
  }, { once: true })
})
