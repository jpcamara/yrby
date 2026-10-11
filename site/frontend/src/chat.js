// A group chat. Sent messages live in the document: a Y.Array named
// `messages`, where each message is a Y.Map { id, from, name, color, text, at,
// reactions }. `reactions` is a nested Y.Map from participant id to emoji, so
// two people reacting at once write different keys and both are kept.
//
// What you're typing isn't in the document. It goes in your awareness state as
// `draft`, and the other windows render it as a bubble that fills in as you
// type. The server relays awareness to the room and never stores it, so drafts
// don't add to the document's history, and a closed tab takes its draft with
// it. Sending pushes a message and clears the draft.
//
// All text from the document and from awareness is set with textContent.
import * as Y from "yjs"
import { connectRoom, uid, user, wireStoredPanel } from "./room.js"

const MAX_LENGTH = 1000 // characters per message, and per draft
const MAX_MESSAGES = 200 // the room keeps the newest 200
const REACTIONS = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
const RUN_GAP = 5 * 60 * 1000 // a new name and time line after 5 minutes
const LONG_PRESS = 450 // ms

// This window's participant id. Messages and reactions are keyed by it. Like
// the name and color in room.js, it's new on every page load.
const me = uid()

const root = document.getElementById("chat")
const ydoc = new Y.Doc()
const messages = ydoc.getArray("messages")
const provider = connectRoom(ydoc, root)
const awareness = provider.awareness

window.__yrby = { provider, ydoc, messages, user, me }

// --- Markup -------------------------------------------------------------------
const thread = el("div", "chat-thread")
thread.id = "thread"
thread.setAttribute("role", "log")
thread.setAttribute("aria-label", "Messages")
const list = el("div", "chat-list")
const empty = el("p", "chat-empty", "No messages yet. Type something, and the other window sees it as you type.")
const drafts = el("div", "chat-drafts")
drafts.setAttribute("aria-live", "off")
thread.append(empty, list, drafts)

const jump = el("button", "chat-jump", "New messages ↓")
jump.type = "button"
jump.hidden = true

const form = el("form", "chat-composer")
const input = el("textarea", "chat-input")
input.id = "chat-input"
input.rows = 1
input.maxLength = MAX_LENGTH
input.placeholder = "Message"
input.setAttribute("aria-label", "Message")
input.enterKeyHint = "send"
const send = el("button", "chat-send", "Send")
send.type = "submit"
form.append(input, send)

const frame = el("div", "chat-frame")
frame.append(thread, jump, form)
root.append(frame)

function el(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

// Colors come from other people's documents and awareness states, so only a
// plain hex color is used as a style value.
const safeColor = (c) => (typeof c === "string" && /^#[0-9a-f]{6}$/i.test(c) ? c : "#cfc8bc")
const clip = (s) => String(s ?? "").slice(0, MAX_LENGTH)
const timeOf = (at) =>
  Number.isFinite(at) ? new Date(at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : ""

// --- Scrolling ----------------------------------------------------------------
// Stay at the bottom when you're already there. If you've scrolled up to read,
// leave the thread where it is and show a button instead.
const atBottom = () => thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40
const toBottom = () => {
  thread.scrollTop = thread.scrollHeight
  jump.hidden = true
}
function keepPinned(update, { announce = false } = {}) {
  const pinned = atBottom()
  update()
  if (pinned) toBottom()
  else if (announce) jump.hidden = false
}
// Whether the thread was at the bottom after the last scroll. A resize, like a
// phone keyboard opening, doesn't scroll, so this keeps the newest message in
// view when the box gets shorter.
let stuck = true
thread.addEventListener("scroll", () => {
  stuck = atBottom()
  if (stuck) jump.hidden = true
})
new ResizeObserver(() => { if (stuck) toBottom() }).observe(thread)
jump.addEventListener("click", toBottom)

// --- Messages -----------------------------------------------------------------
let pickerFor = null // the id of the message whose reaction picker is open

function react(message, emoji) {
  const reactions = message.get("reactions")
  if (!(reactions instanceof Y.Map)) return
  if (reactions.get(me) === emoji) reactions.delete(me)
  else reactions.set(me, emoji)
}

function reactionBadges(message) {
  const reactions = message.get("reactions")
  if (!(reactions instanceof Y.Map) || reactions.size === 0) return null
  const counts = new Map()
  for (const emoji of reactions.values()) {
    if (REACTIONS.includes(emoji)) counts.set(emoji, (counts.get(emoji) || 0) + 1)
  }
  if (counts.size === 0) return null
  const mine = reactions.get(me)
  const row = el("div", "chat-reactions")
  for (const emoji of REACTIONS) {
    if (!counts.has(emoji)) continue
    const badge = el("span", "chat-reaction")
    if (emoji === mine) badge.classList.add("mine")
    badge.dataset.emoji = emoji
    badge.append(el("span", "", emoji))
    if (counts.get(emoji) > 1) badge.append(el("span", "chat-reaction-count", String(counts.get(emoji))))
    row.append(badge)
  }
  return row
}

function picker(message) {
  const mine = message.get("reactions")?.get?.(me)
  const bar = el("div", "chat-picker")
  bar.setAttribute("role", "toolbar")
  bar.setAttribute("aria-label", "React")
  for (const emoji of REACTIONS) {
    const button = el("button", "chat-pick", emoji)
    button.type = "button"
    button.dataset.emoji = emoji
    button.setAttribute("aria-pressed", String(emoji === mine))
    button.addEventListener("click", (e) => {
      e.stopPropagation()
      react(message, emoji)
      pickerFor = null
      keepPinned(renderMessages)
    })
    bar.append(button)
  }
  return bar
}

function togglePicker(id) {
  pickerFor = pickerFor === id ? null : id
  keepPinned(renderMessages)
  if (pickerFor) list.querySelector(`[data-id="${CSS.escape(id)}"] .chat-pick`)?.focus({ preventScroll: true })
}

// Tap or click a bubble to react. A long press does the same on touch screens,
// where a tap can be the start of a scroll. A click that ends a text selection
// is left alone, so you can still copy a message.
function bindReactions(bubble, id) {
  let timer = null
  let pressed = false
  bubble.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return
    pressed = false
    timer = setTimeout(() => { pressed = true; togglePicker(id) }, LONG_PRESS)
  })
  const cancel = () => clearTimeout(timer)
  bubble.addEventListener("pointerup", cancel)
  bubble.addEventListener("pointercancel", cancel)
  bubble.addEventListener("pointermove", cancel)
  bubble.addEventListener("contextmenu", (e) => { if (e.pointerType === "touch" || pressed) e.preventDefault() })
  bubble.addEventListener("click", () => {
    if (pressed) { pressed = false; return }
    if (String(window.getSelection()).length > 0) return
    togglePicker(id)
  })
  bubble.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); togglePicker(id) }
  })
}

function renderMessages() {
  const items = messages.toArray().filter((m) => m instanceof Y.Map)
  if (pickerFor && !items.some((m) => m.get("id") === pickerFor)) pickerFor = null
  empty.hidden = items.length > 0

  const rows = []
  let prev = null
  for (const m of items) {
    const id = String(m.get("id"))
    const from = m.get("from")
    const mine = from === me
    const at = m.get("at")
    const startsRun = !prev || prev.get("from") !== from || !(at - prev.get("at") < RUN_GAP)
    prev = m

    const row = el("div", `chat-row ${mine ? "mine" : "theirs"}`)
    row.dataset.id = id
    if (startsRun) {
      const meta = el("div", "chat-meta")
      if (!mine) {
        const name = el("span", "chat-name", clip(m.get("name")).slice(0, 40))
        name.style.setProperty("--peer", safeColor(m.get("color")))
        meta.append(name)
      }
      meta.append(el("time", "chat-time", timeOf(at)))
      row.append(meta)
    }
    if (pickerFor === id) row.append(picker(m))

    const bubble = el("div", "chat-bubble", clip(m.get("text")))
    bubble.tabIndex = 0
    bubble.setAttribute("aria-haspopup", "true")
    bubble.setAttribute("aria-expanded", String(pickerFor === id))
    if (Number.isFinite(at)) bubble.title = new Date(at).toLocaleString()
    if (mine) bubble.style.background = safeColor(user.color)
    bindReactions(bubble, id)
    row.append(bubble)

    const badges = reactionBadges(m)
    if (badges) row.append(badges)
    rows.push(row)
  }
  list.replaceChildren(...rows)
}

// --- Drafts -------------------------------------------------------------------
// One bubble per person with a non-empty draft, in their color, ending in a
// blinking caret. It goes away when they send or clear the box.
function renderDrafts() {
  const bubbles = []
  for (const [clientId, state] of awareness.getStates()) {
    if (clientId === awareness.clientID || !state?.user) continue
    const text = clip(state.draft)
    if (!text.trim()) continue
    const color = safeColor(state.user.color)
    const row = el("div", "chat-row theirs chat-draft")
    row.dataset.client = String(clientId)
    const meta = el("div", "chat-meta")
    const name = el("span", "chat-name", clip(state.user.name).slice(0, 40))
    name.style.setProperty("--peer", color)
    meta.append(name, el("span", "chat-time", "typing"))
    const bubble = el("div", "chat-bubble")
    bubble.style.setProperty("--peer", color)
    bubble.append(el("span", "chat-draft-text", text), el("span", "chat-caret"))
    row.append(meta, bubble)
    bubbles.push(row)
  }
  drafts.replaceChildren(...bubbles)
}

// --- Composer -----------------------------------------------------------------
const setDraft = (text) => awareness.setLocalStateField("draft", clip(text))

function grow() {
  input.style.height = "auto"
  input.style.height = `${Math.min(input.scrollHeight, 160)}px`
}

function sendMessage() {
  const text = clip(input.value)
  if (!text.trim()) return
  ydoc.transact(() => {
    const m = new Y.Map()
    m.set("id", uid())
    m.set("from", me)
    m.set("name", user.name)
    m.set("color", user.color)
    m.set("text", text)
    m.set("at", Date.now())
    // Created with the message, not on the first reaction. Two people adding
    // the first reaction at once would each set a new Y.Map, and one map
    // (with its reaction) would lose.
    m.set("reactions", new Y.Map())
    messages.push([m])
    // Keep the newest MAX_MESSAGES. Two windows trimming at the same moment
    // can each delete the same oldest message, which leaves the thread one
    // over until the next send.
    if (messages.length > MAX_MESSAGES) messages.delete(0, messages.length - MAX_MESSAGES)
  })
  input.value = ""
  grow()
  setDraft("")
  toBottom()
}

input.addEventListener("input", () => {
  grow()
  setDraft(input.value)
})
input.addEventListener("keydown", (e) => {
  // Shift+Enter adds a line. Enter during IME composition picks a candidate.
  if (e.key !== "Enter" || e.shiftKey || e.isComposing) return
  e.preventDefault()
  sendMessage()
})
form.addEventListener("submit", (e) => {
  e.preventDefault()
  sendMessage()
  input.focus()
})

// Close the picker on Escape or a click anywhere else.
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && pickerFor) { pickerFor = null; renderMessages() }
})
document.addEventListener("click", (e) => {
  if (pickerFor && !e.target.closest?.(".chat-bubble, .chat-picker")) { pickerFor = null; renderMessages() }
})

// A reconnect resets the awareness state to just the user (see connectRoom),
// so share the draft again.
provider.onStatusChange(({ status }) => {
  if (status === "synced" && input.value) setDraft(input.value)
})

messages.observeDeep((events) => {
  // Only a new message counts as news. A reaction changes a nested map.
  const added = events.some((e) => e.target === messages && e.changes.added.size > 0)
  keepPinned(renderMessages, { announce: added })
})
awareness.on("change", () => keepPinned(renderDrafts))

renderMessages()
renderDrafts()
wireStoredPanel(ydoc)
provider.whenSynced.then(toBottom)
provider.connect()
