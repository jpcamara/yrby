// A markdown document: a Y.Text bound to CodeMirror 6 with markdown syntax
// styling, a rendered preview beside it, remote cursors from awareness, and
// the same roster and agent log as the Lexxy page. yrby syncs the Y.Text;
// the agent works on the markdown as text.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { EditorState } from "@codemirror/state"
import { EditorView, minimalSetup } from "codemirror"
import { markdown, markdownLanguage } from "@codemirror/lang-markdown"
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language"
import { tags as t } from "@lezer/highlight"
import { yCollab } from "y-codemirror.next"
import { marked } from "marked"

const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS), colorLight: "rgba(124, 58, 237, .15)" }

const mount = document.getElementById("editor")
const previewEl = document.getElementById("preview")
const statusEl = document.getElementById("status")
const documentId = mount.dataset.documentId

const ydoc = new Y.Doc()
const ytext = ydoc.getText("markdown")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
provider.awareness.setLocalStateField("user", user)
const awareness = provider.awareness
window.__yrb = { provider, ydoc, ytext, user }

// Markdown styled in place: headings sized, emphasis and strong shown, code
// in mono, the markup characters dimmed so the text reads as a document.
const markdownStyle = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.7em", fontWeight: "700", lineHeight: "1.3" },
  { tag: t.heading2, fontSize: "1.4em", fontWeight: "700", lineHeight: "1.3" },
  { tag: t.heading3, fontSize: "1.15em", fontWeight: "700" },
  { tag: [t.heading4, t.heading5, t.heading6], fontWeight: "700" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: t.link, color: "#2563eb", textDecoration: "underline" },
  { tag: t.url, color: "#6b7280" },
  { tag: t.monospace, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: ".92em", background: "#f3f4f6", borderRadius: "3px" },
  { tag: t.quote, color: "#6b7280", fontStyle: "italic" },
  { tag: [t.processingInstruction, t.meta, t.contentSeparator], color: "#9ca3af" },
])

const theme = EditorView.theme({
  "&": { background: "#fff", border: "1px solid #e5e7eb", borderRadius: "8px", fontSize: "16px" },
  "&.cm-focused": { outline: "2px solid #c4b5fd", outlineOffset: "1px" },
  ".cm-content": { fontFamily: "-apple-system, BlinkMacSystemFont, Inter, system-ui, sans-serif", lineHeight: "1.6", padding: "1rem 1.25rem", caretColor: "#111" },
  ".cm-scroller": { overflow: "auto", minHeight: "24rem", maxHeight: "70vh" },
  ".cm-line": { padding: "0" },
  ".cm-ySelectionInfo": { opacity: "1", fontFamily: "system-ui, sans-serif", fontSize: ".72rem", padding: ".1rem .35rem", borderRadius: "4px", top: "-1.4em" },
  ".cm-ySelection": { borderRadius: "2px" },
})

const view = new EditorView({
  parent: mount,
  state: EditorState.create({
    doc: ytext.toString(),
    extensions: [
      minimalSetup,
      EditorView.lineWrapping,
      markdown({ base: markdownLanguage }),
      syntaxHighlighting(markdownStyle),
      theme,
      yCollab(ytext, awareness),
    ],
  }),
})

window.__yrb.view = view

// The rendered view, from the same text. Collaborators' own content only.
let previewTimer = null
function renderPreview() {
  if (!previewEl) return
  clearTimeout(previewTimer)
  previewTimer = setTimeout(() => { previewEl.innerHTML = marked.parse(ytext.toString()) }, 80)
}
ytext.observe(renderPreview)

// Roster and agent log, from awareness. y-codemirror carries the person in
// `user`; the agent adds `status`, `detail` and `at`.
const rosterEl = document.getElementById("presence-roster")
// The ledger: what the agent is doing, from its presence. Each status change
// is an entry with its time and the reason the model gave; while the model
// reasons, the current entry shows its thinking as it streams. Oldest first,
// scrolled to the newest.
function renderRoster() {
  if (!rosterEl) return
  rosterEl.innerHTML = [...awareness.getStates().values()].map((s) => {
    const name = s?.identity?.name ?? s?.user?.name ?? "someone"
    const color = s?.user?.color ?? "#999"
    const status = s?.status ? `<span class="status">${escapeHtml(s.status)}</span>` : ""
    return `<span class="peer" style="--c:${color}">${escapeHtml(name)}${status}</span>`
  }).join("")
}
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
function refreshAgentLabels() {
  // The remote cursor label is drawn from the state when the cursor moves;
  // keep it current when only the status changed.
  for (const s of awareness.getStates().values()) {
    const identity = s?.identity?.name
    if (!identity || !s?.user?.name || s.user.name === identity) continue
    for (const el of document.querySelectorAll(".cm-ySelectionInfo")) {
      if (el.textContent.startsWith(identity)) el.textContent = s.user.name
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
  if (!e.target.closest(".agent-actions, #agent-bar")) noteInteraction()
})
document.addEventListener("wheel", () => { if (Date.now() > ourScrollUntil) noteInteraction() }, { passive: true })

// The agent's caret as a document index. The relative position it sends
// names the character after its insertion point, which stays the same while
// it writes, so the index is what changes.
function agentPosition(s) {
  const index = agentIndex(s)
  return index == null ? null : String(index)
}
function agentIndex(s = agentState()) {
  const rel = s?.cursor?.head ?? s?.cursor?.anchor
  if (!rel) return null
  const abs = Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(rel), ydoc)
  return abs && abs.type === ytext ? abs.index : null
}
function revealAgent() {
  const index = agentIndex()
  if (index == null) return
  view.dispatch({ effects: EditorView.scrollIntoView(index, { y: "center" }) })
}
document.getElementById("jump-to-agent")?.addEventListener("click", (e) => { e.preventDefault(); ourScrollUntil = Date.now() + 1500; revealAgent() })
view.dom.addEventListener("input", () => { lastTyped = Date.now() })
view.dom.addEventListener("keydown", () => { lastTyped = Date.now() })

// The things you can say to the agent, as buttons: each puts the line on a
// new line after the current one and leaves the caret at its end.
function sayToAgent(text) {
  const line = view.state.doc.lineAt(view.state.selection.main.head)
  const insert = `\n${text}`
  view.dispatch({ changes: { from: line.to, insert }, selection: { anchor: line.to + insert.length }, scrollIntoView: true })
  view.focus()
  lastTyped = Date.now()
}
for (const button of document.querySelectorAll(".agent-actions button")) {
  button.addEventListener("click", () => sayToAgent(button.dataset.say))
}
awareness.on("change", renderBar)
awareness.on("change", followAgent)
renderBar()
window.__yrb.follow = { state: () => ({ sinceTyped: Date.now() - lastTyped, lastAgentPos, index: agentIndex(), checked: followEl?.checked }), reveal: revealAgent }
awareness.on("update", renderRoster)
awareness.on("change", renderAgentLog)
awareness.on("change", refreshAgentLabels)
renderRoster()

statusEl.dataset.state = "connecting"
statusEl.textContent = `connecting as ${user.name}…`
provider.onStatusChange(({ status }) => {
  statusEl.dataset.state = status === "synced" ? "synced" : "connecting"
  statusEl.textContent = status === "synced" ? `synced, editing as ${user.name}` : `${status}…`
})
provider.whenSynced.then(() => {
  if (ytext.length === 0) {
    ytext.insert(0, "# Launch readiness\n\nThis document tracks our go-live checklist for the payments service.\n\n" +
      "## Rollout\n\nWe roll out to 5% of traffic first, then 50%, then everyone.\n\n" +
      "## For the agent\n\n- [ ] Draft the rollback plan under Rollout\n- [ ] Draft the go/no-go criteria\n")
  }
  renderPreview()
})
provider.connect()
