// The Lexxy demo, on lexxy-realtime. The page renders the markup the gem's
// form helper renders: a <yrby-document> around the Lexxy editor and a
// <lexxy-collaboration> inside it. Importing lexxy-realtime registers both
// elements. <yrby-document> subscribes to NoteChannel with the room token as
// its grant and holds the Yjs document, and <lexxy-collaboration> binds the
// editor to that document once it syncs.
//
// This file adds the parts every demo page has: the AnyCable consumer from
// room.js, the room bar, presence chips, the status line, and the stored
// HTML panel.
import "@37signals/lexxy"
// Lexxy's package exports only include the JS entry, so import the stylesheet
// by path. Bun bundles it with lexxy-realtime's caret styles into
// public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import "lexxy-realtime/lexxy-realtime.css"
import { setConsumer } from "lexxy-realtime" // registers <lexxy-collaboration> and <yrby-document>
import { roomConsumer, setupRoomPage, showRoomState, user, wireStoredPanel } from "./room.js"

// <yrby-document> asks for a consumer once this script has run, so setting
// the factory here comes early enough. It gets the same notice-aware AnyCable
// consumer as the other demos, with whisper hidden.
setConsumer(() => roomConsumer())

const element = document.querySelector("yrby-document")

// The cursor name and color come from the random identity room.js picks for
// every demo. The element reads them when it binds, after the first sync.
const collab = element.querySelector("lexxy-collaboration")
collab.setAttribute("name", user.name)
collab.setAttribute("color", user.color)

setupRoomPage()

// Each yrby:synced is a new document session, and its signal aborts when the
// session ends. The "Stored HTML" panel shows the note.body column, which
// Y::Lexxy renders in Ruby with no browser involved. It refreshes after each
// change while it's open.
// "Invite the agent" asks the server to start the demo agent in this room.
// The agent joins over the cable like another browser, so everything after
// the invitation shows up through the document and presence.
const invite = document.getElementById("invite-agent")
const agentStatus = document.getElementById("agent-status")
const AGENT_STATUS = {
  joining: "The agent is joining. Start a line with @agent to ask it something.",
  here: "The agent is already in this room.",
  busy: "Every agent is busy right now. Try again in a few minutes.",
}
invite?.addEventListener("click", async () => {
  invite.disabled = true
  agentStatus.textContent = "Inviting…"
  try {
    const response = await fetch(invite.dataset.url, { method: "POST" })
    const json = response.headers.get("content-type")?.includes("json") ? await response.json() : {}
    agentStatus.textContent = AGENT_STATUS[json.status] ??
      (response.status === 429 ? "You've invited the agent a lot this hour. Try again later." : "The agent couldn't join this room.")
  } catch {
    agentStatus.textContent = "Couldn't reach the server."
  } finally {
    invite.disabled = false
  }
})

element.addEventListener("yrby:synced", ({ detail }) => {
  window.__yrby = { provider: detail.provider, ydoc: detail.doc, user }
  const stopRoomState = showRoomState(detail.provider)
  const stopStoredPanel = wireStoredPanel(detail.doc)
  detail.signal.addEventListener("abort", () => {
    stopRoomState()
    stopStoredPanel()
  }, { once: true })
})
