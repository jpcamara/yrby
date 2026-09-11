// Alternative editor for the demo: a real Lexxy (Lexical) collaborative editor
// driven by `lexxy-realtime`, against the SAME DocumentChannel the Tiptap page
// uses. Nothing on the server changes — both editors speak the yrby
// y-websocket protocol — so this is a drop-in second front end.
//
// lexxy-realtime ships the `<lexxy-collaboration>` custom element and a
// `YrbyProvider` (the yrby-client ActionCableProvider). The collaboration
// element owns the editor binding, the empty-doc bootstrap, and remote cursors;
// we just create the doc/provider, mount it inside a `<lexxy-editor>`, and
// connect.
import "@37signals/lexxy"
// Lexxy's package `exports` only expose the JS entry, so reach the stylesheet by
// path. Bun bundles it (and its relative @imports) and emits ../public/lexxy.css.
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import * as Y from "yjs"
import { $getSelection, $getRoot, $createParagraphNode, $createTextNode, $isRangeSelection } from "lexical"
import { createConsumer } from "@rails/actioncable"
import { YrbyProvider } from "lexxy-realtime" // also registers <lexxy-collaboration>

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]

const editorEl = document.getElementById("editor") // <lexxy-editor>
const statusEl = document.getElementById("status")
const documentId = editorEl.dataset.documentId

const user = {
  name: NAMES[Math.floor(Math.random() * NAMES.length)],
  color: COLORS[Math.floor(Math.random() * COLORS.length)],
}

const ydoc = new Y.Doc()
const consumer = createConsumer()
const provider = new YrbyProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
const awareness = provider.awareness // the provider owns presence; read it back

// Exposed for the browser console (parity with the Tiptap page's window.__yrb).
// encodeState feeds the render-parity e2e: the doc's full state as base64.
window.__yrb = {
  provider,
  ydoc,
  awareness,
  user,
  encodeState: () => {
    const bytes = Y.encodeStateAsUpdate(ydoc)
    let binary = ""
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    }
    return btoa(binary)
  },
}

// A presence roster: everyone the awareness protocol knows about, including the

// The ledger: what the agent is doing, from its presence. Each status change
// is an entry with its time and the reason the model gave; while the model
// reasons, the current entry shows its thinking as it streams. Oldest first,
// scrolled to the newest.
const logEl = document.getElementById("agent-log")
const lastEntry = new Map()
function escapeHtml(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])
}
function renderAgentLog() {
  if (!logEl) return
  let changed = false
  for (const [clientId, s] of awareness.getStates()) {
    if (!s?.status) continue
    const key = `${s.status}|${s.detail ?? ""}`
    let entry = lastEntry.get(clientId)
    if (!entry || entry.key !== key) {
      const time = new Date(s.at ?? Date.now()).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })
      const li = document.createElement("li")
      li.innerHTML = `<time>${time}</time> <b>${escapeHtml(s.status)}</b>${s.detail ? ` <span>${escapeHtml(s.detail)}</span>` : ""}<div class="thinking" hidden></div>`
      logEl.append(li)
      while (logEl.children.length > 60) logEl.firstChild.remove()
      entry = { key, li, thinking: "" }
      lastEntry.set(clientId, entry)
      changed = true
    }
    const thinking = s.thinking ?? ""
    if (thinking !== entry.thinking) {
      entry.thinking = thinking
      const div = entry.li.querySelector(".thinking")
      div.textContent = thinking
      div.hidden = thinking.length === 0
      changed = true
    }
  }
  if (changed) logEl.scrollTop = logEl.scrollHeight
}

// Ruby agent, which broadcasts its awareness over the same DocumentChannel.
const rosterEl = document.getElementById("presence-roster")
function renderRoster() {
  if (!rosterEl) return
  const peers = [...awareness.getStates().values()]
  rosterEl.innerHTML = peers.map((s) => {
    const name = s?.awarenessData?.name ?? s?.name ?? "someone"
    const color = s?.color ?? s?.awarenessData?.color ?? "#999"
    const status = s?.status ? `<span class="status">${s.status}</span>` : ""
    return `<span class="peer" style="--c:${color}">${name}${status}</span>`
  }).join("")
}
awareness.on("update", renderRoster)
function refreshAgentLabels() {
  // Lexical writes a remote cursor's label once, when the cursor appears,
  // so the status in the agent's name would freeze there. Keep it current.
  for (const s of awareness.getStates().values()) {
    const identity = s?.awarenessData?.name
    if (!identity || !s?.name || s.name === identity) continue
    for (const el of document.querySelectorAll(".lexxy-collab-cursor__name")) {
      if (el.textContent.startsWith(identity)) el.textContent = s.name
    }
  }
}
// The agent bar: pinned under the page header, always in view. It shows what
// the agent is doing now, a link to jump to its cursor, and a switch for
// following it. Following scrolls the editor to the agent's cursor when it
// moves, and holds off for a few seconds after you type.
const barEl = document.getElementById("agent-bar")
const followEl = document.getElementById("agent-follow")
let lastTyped = 0
let lastAgentPos = null
function agentState() {
  for (const s of awareness.getStates().values()) if (s?.status) return s
  return null
}
function renderBar() {
  if (!barEl) return
  const s = agentState()
  const statusEl = barEl.querySelector(".bar-status")
  const detailEl = barEl.querySelector(".bar-detail")
  if (!s) { statusEl.textContent = "no agent here yet"; detailEl.textContent = ""; barEl.classList.remove("live"); return }
  barEl.classList.add("live")
  statusEl.textContent = s.status
  detailEl.textContent = s.detail ?? ""
}
function followAgent() {
  const s = agentState()
  const pos = agentPosition(s)
  if (pos == null || pos === lastAgentPos) return
  lastAgentPos = pos
  if (!followEl?.checked || Date.now() - lastTyped < 4000) return
  revealAgent()
}

function agentPosition(s) {
  const p = s?.focusPos ?? s?.anchorPos
  return p ? JSON.stringify(p) : null
}
// Lexical draws the agent's cursor as an element; scroll it into view once
// it has been drawn for the new position.
function revealAgent() {
  requestAnimationFrame(() => {
    const identity = agentState()?.awarenessData?.name
    const name = [...document.querySelectorAll(".lexxy-collab-cursor__name")].find((el) => identity && el.textContent.startsWith(identity))
    const cursor = name?.closest(".lexxy-collab-cursor") ?? name
    cursor?.scrollIntoView({ block: "center", behavior: "smooth" })
  })
}
document.getElementById("jump-to-agent")?.addEventListener("click", (e) => { e.preventDefault(); revealAgent() })
document.querySelector("#editor [contenteditable=true]")?.addEventListener("input", () => { lastTyped = Date.now() })

// The things you can say to the agent, as buttons: each puts the line in a
// new paragraph after the one you are in and leaves the caret at its end.
function sayToAgent(text) {
  const editor = document.querySelector("lexxy-editor")?.editor
  if (!editor) return
  editor.update(() => {
    const paragraph = $createParagraphNode()
    paragraph.append($createTextNode(text))
    const selection = $getSelection()
    const top = $isRangeSelection(selection) ? selection.anchor.getNode().getTopLevelElement() : null
    if (top) top.insertAfter(paragraph)
    else $getRoot().append(paragraph)
    paragraph.selectEnd()
  })
  editor.focus()
  lastTyped = Date.now()
}
for (const button of document.querySelectorAll(".agent-actions button")) {
  button.addEventListener("click", () => sayToAgent(button.dataset.say))
}
awareness.on("change", renderBar)
awareness.on("change", followAgent)
renderBar()
awareness.on("change", renderAgentLog)
awareness.on("change", refreshAgentLabels)
renderRoster()

const setStatus = (state, text) => {
  statusEl.dataset.state = state
  statusEl.textContent = text
}
setStatus("connecting", `connecting as ${user.name}…`)
provider.onStatusChange(({ status }) => {
  setStatus(status, status === "synced" ? `synced, editing as ${user.name}` : `${status}…`)
})

// Mount the collaboration element once Lexxy has initialized its editor. It
// reads identity from the attributes and uses the doc/awareness/provider we set
// on it directly (rather than creating its own).
function mount() {
  const collab = document.createElement("lexxy-collaboration")
  collab.setAttribute("doc-id", documentId)
  collab.setAttribute("name", user.name)
  collab.setAttribute("color", user.color)
  collab.setAttribute("channel-name", "DocumentChannel")
  collab.setAttribute("channel-params", JSON.stringify({ id: documentId }))
  collab.consumer = consumer
  collab.doc = ydoc
  collab.provider = provider
  editorEl.appendChild(collab)
  provider.connect() // the element wires the binding; we own the connection
}

if (editorEl.editor) {
  mount()
} else {
  editorEl.addEventListener("lexxy:initialize", mount, { once: true })
}
