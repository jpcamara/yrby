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
const logEntries = ydoc.getArray("agent-log")
let logRendered = 0
function escapeHtml(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])
}
// The ledger is part of the document: the agent appends {at, status, detail}
// entries to a Y.Array, so every page shows the same history and a reload
// keeps it. Entries are appended as they arrive; a trim at the front
// redraws the whole list.
function renderAgentLog(event) {
  if (!logEl) return
  const all = logEntries.toArray()
  if (event?.changes?.deleted?.size || all.length < logRendered) { logEl.replaceChildren(); logRendered = 0 }
  for (const raw of all.slice(logRendered)) {
    const e = typeof raw?.toJSON === "function" ? raw.toJSON() : raw // entries arrive as Y.Maps
    const time = new Date(e.at ?? Date.now()).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })
    const li = document.createElement("li")
    li.innerHTML = `<time>${time}</time> <b>${escapeHtml(e.status)}</b>${e.detail ? ` <span>${escapeHtml(e.detail)}</span>` : ""}`
    logEl.append(li)
  }
  if (all.length !== logRendered) { logRendered = all.length; logEl.scrollTop = logEl.scrollHeight }
}
logEntries.observe(renderAgentLog)
renderAgentLog()
// The agent files its reasoning by what it is for: "the review" and a
// section it is drafting each get their own block, from its presence. A
// block follows the newest entry while its stream runs and stays where it
// was when the stream ends.
const thoughtBlocks = new Map()
function renderThoughts() {
  if (!logEl || !logEl.lastElementChild) return
  let changed = false
  for (const [clientId, s] of awareness.getStates()) {
    if (!s?.status) continue
    const thoughts = typeof s.thinking === "string" ? { [s.status]: s.thinking } : (s.thinking ?? {})
    const blocks = thoughtBlocks.get(clientId) ?? new Map()
    thoughtBlocks.set(clientId, blocks)
    for (const label of [...blocks.keys()]) if (!(label in thoughts)) blocks.delete(label)
    const li = logEl.lastElementChild
    for (const [label, text] of Object.entries(thoughts)) {
      let div = blocks.get(label)
      if (!div) {
        div = document.createElement("div")
        div.className = "thinking"
        div.dataset.label = label === s.status ? "" : label
        blocks.set(label, div)
      }
      if (div.parentElement !== li) { li.append(div); changed = true }
      if (div.dataset.full !== text) { div.dataset.full = text; renderThinking(div); changed = true }
    }
  }
  if (changed) logEl.scrollTop = logEl.scrollHeight
}
// Folded, a block shows its last few lines, enough to see where the model
// is going; a click opens the whole thing.
const THINKING_TAIL = 240
function renderThinking(div) {
  const full = div.dataset.full ?? ""
  div.hidden = full.length === 0
  const folded = !div.classList.contains("open") && full.length > THINKING_TAIL
  div.classList.toggle("folded", folded)
  div.title = folded ? "click to read all of it" : ""
  const text = folded ? "\u2026" + full.slice(-THINKING_TAIL).replace(/^\S*\s+/, " ") : full
  div.textContent = div.dataset.label ? `${div.dataset.label}: ${text}` : text
}
logEl?.addEventListener("click", (e) => {
  const div = e.target.closest(".thinking")
  if (!div) return
  div.classList.toggle("open")
  renderThinking(div)
})
const rosterEl = document.getElementById("presence-roster")
// A presence roster: everyone the awareness protocol knows about, including the agent.
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
let agentWasHere = false
const inviteEl = document.querySelector(".invite-agent")
function renderBar() {
  if (!barEl) return
  const s = agentState()
  const statusEl = barEl.querySelector(".bar-status")
  const detailEl = barEl.querySelector(".bar-detail")
  if (inviteEl) { inviteEl.disabled = !!s; inviteEl.textContent = s ? "The agent is here" : "Invite the agent" }
  if (!s) {
    statusEl.textContent = agentWasHere ? "the agent left" : "no agent here yet"
    detailEl.textContent = agentWasHere ? "invite it again to keep going" : ""
    barEl.classList.remove("live")
    return
  }
  if (!agentWasHere && followEl?.checked) setTimeout(revealAgent, 300) // it just arrived: show where
  agentWasHere = true
  barEl.classList.add("live")
  statusEl.textContent = s.status
  detailEl.textContent = s.detail ?? ""
}
// Follow only while you are not doing anything: typing, clicking, scrolling
// and keys all hold it for a while (not selection changes, which remote edits
// cause too), so it never pulls the page
// away from what you are reading or writing. "jump to it" always works.
const HOLD_AFTER_INTERACTION = 15000
let ourScrollUntil = 0
function noteInteraction() { lastTyped = Date.now() }
function followAgent() {
  const s = agentState()
  const pos = agentPosition(s)
  if (pos == null || pos === lastAgentPos) return
  lastAgentPos = pos
  if (!followEl?.checked || Date.now() - lastTyped < HOLD_AFTER_INTERACTION) return
  ourScrollUntil = Date.now() + 1500
  revealAgent()
}
for (const type of ["keydown", "mousedown", "touchstart"]) document.addEventListener(type, (e) => {
  if (!e.target.closest(".agent-actions, #agent-bar, .invite-agent")) noteInteraction()
})
document.addEventListener("wheel", () => { if (Date.now() > ourScrollUntil) noteInteraction() }, { passive: true })

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
document.getElementById("jump-to-agent")?.addEventListener("click", (e) => { e.preventDefault(); ourScrollUntil = Date.now() + 1500; revealAgent() })
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
window.__yrb.follow = { state: () => ({ sinceTyped: Date.now() - lastTyped, lastAgentPos, checked: followEl?.checked, scrollY: window.scrollY }), reveal: revealAgent }
renderBar()
awareness.on("update", renderRoster)
awareness.on("change", renderThoughts)
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
