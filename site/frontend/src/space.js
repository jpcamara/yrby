// The Lexxy room as a shared page with agents. It's the same document as the
// Lexxy demo, through the same <yrby-document> and <lexxy-collaboration>.
// This file adds what the page does with agents:
//
// - Each person can invite their own agent. It's a Ruby process
//   (PageAgentJob) that joins the room over the cable like a browser.
// - Select text and choose "Ask for change" to ask your agent for new wording.
//   The request goes into the document's "asks" map, so every browser in the
//   room shows it.
// - The agent covers the selection with its own selection, its name tag
//   counts the seconds, and its proposal streams in under the paragraph.
// - Anyone can Accept, Undo, or ask for a change. Accept edits the page in
//   that person's browser, like typing does.
//
// app/agents/page_agent.rb has the agent's side and the shape of an ask.
import "@37signals/lexxy"
import "../node_modules/@37signals/lexxy/dist/stylesheets/lexxy.css"
import "lexxy-realtime/lexxy-realtime.css"
import "./space.css"
import * as Y from "yjs"
import { setConsumer } from "lexxy-realtime" // registers <lexxy-collaboration> and <yrby-document>
import { roomConsumer, setupRoomPage, uid, user } from "./room.js"

// --- who you are -------------------------------------------------------------

// Your agent belongs to you, so you keep the same id, name, and color when the
// page reloads. sessionStorage keeps them for this tab only, so a second
// window is a second person.
const me = (() => {
  try {
    const saved = JSON.parse(sessionStorage.getItem("yrby-space-person"))
    if (saved?.id) return saved
  } catch { /* storage blocked or empty */ }
  const fresh = { id: uid(), name: user.name, color: user.color }
  try { sessionStorage.setItem("yrby-space-person", JSON.stringify(fresh)) } catch { /* fine */ }
  return fresh
})()
user.name = me.name
user.color = me.color

setConsumer(() => roomConsumer())
setupRoomPage()

const page = document.querySelector(".space-page")
const element = document.querySelector("yrby-document")
const collab = element.querySelector("lexxy-collaboration")
collab.setAttribute("name", me.name)
collab.setAttribute("color", me.color)

const OPEN = new Set(["asked", "working", "proposed", "failed"])

// --- the toolbar ------------------------------------------------------------

const inviteButton = document.getElementById("invite-agent")
const shareButton = document.getElementById("share")
const avatars = document.getElementById("avatars")
const statusLine = document.getElementById("status")

shareButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(location.href)
    flash(shareButton, "Link copied")
  } catch {
    flash(shareButton, "Copy the address bar")
  }
})

function flash(button, text) {
  const label = button.querySelector("span") ?? button
  const was = label.textContent
  label.textContent = text
  setTimeout(() => { label.textContent = was }, 1800)
}

// Asks the server to start your agent in this room. It answers "joining",
// "here" when it's already in, or "busy" when the room or the site is full.
async function inviteAgent() {
  const query = new URLSearchParams({ owner: me.id, name: me.name, color: me.color })
  const response = await fetch(`${inviteButton.dataset.url}?${query}`, { method: "POST" })
  const json = response.headers.get("content-type")?.includes("json") ? await response.json() : {}
  if (json.status === "joining" || json.status === "here") return true
  toast(json.status === "busy" ? "Every agent seat is taken right now. Try again in a few minutes."
    : response.status === 429 ? "You've invited an agent a lot this hour. Try again later."
      : "Your agent couldn't join this page.")
  return false
}

inviteButton.addEventListener("click", async () => {
  inviteButton.disabled = true
  try {
    if (await inviteAgent()) inviteButton.querySelector("span").textContent = "Your agent is joining…"
  } catch {
    toast("Couldn't reach the server.")
  } finally {
    inviteButton.disabled = false
  }
})

function toast(text) {
  const el = document.getElementById("toast")
  el.textContent = text
  el.hidden = false
  clearTimeout(toast.timer)
  toast.timer = setTimeout(() => { el.hidden = true }, 4000)
}

// --- the document session ---------------------------------------------------

element.addEventListener("yrby:synced", ({ detail }) => {
  const session = new Session(detail.doc, detail.provider, collab)
  window.__yrby = { ydoc: detail.doc, provider: detail.provider, me }
  detail.signal.addEventListener("abort", () => session.stop(), { once: true })
})

class Session {
  constructor(doc, provider, collab) {
    this.doc = doc
    this.provider = provider
    this.collab = collab
    this.asks = doc.getMap("asks")
    this.cards = new Map() // ask id -> card element
    this.spaced = new Map() // block element -> margin we added under it
    this.stops = []

    const render = () => this.scheduleRender()
    this.asks.observeDeep(render)
    provider.awareness.on("change", render)
    this.stops.push(() => this.asks.unobserveDeep(render), () => provider.awareness.off("change", render))
    const onStatus = ({ status }) => {
      statusLine.dataset.state = status
      statusLine.textContent = status === "synced" ? "Saved" : status === "disconnected" ? "Offline" : "Connecting…"
    }
    this.stops.push(provider.onStatusChange(onStatus))
    onStatus({ status: provider.status })

    const editor = this.editor
    if (editor) this.stops.push(editor.registerUpdateListener(render))
    addEventListener("resize", render)
    this.stops.push(() => removeEventListener("resize", render))
    const tick = setInterval(() => this.tickTimers(), 1000)
    this.stops.push(() => clearInterval(tick))

    this.selectionBar = new SelectionBar(this)
    this.stops.push(() => this.selectionBar.stop())
    this.scheduleRender()
  }

  get editor() { return this.collab.closest("lexxy-editor")?.editor }
  get binding() { return this.collab.binding }

  stop() {
    this.stops.forEach((stop) => stop())
    this.cards.forEach((card) => card.remove())
    this.unspace()
    CSS.highlights?.delete("yrby-ask")
  }

  // Everyone in the room. People set { name, color } through Lexical's
  // presence, and agents add "agent".
  peers() {
    return [...this.provider.awareness.getStates().entries()]
      .filter(([, s]) => s?.name)
      .map(([id, s]) => ({ id, ...s }))
  }

  myAgent() { return this.peers().find((p) => p.agent?.owner === me.id) }

  scheduleRender() {
    if (this.pending) return
    this.pending = requestAnimationFrame(() => {
      this.pending = null
      this.render()
    })
  }

  render() {
    this.renderAvatars()
    this.renderCards()
  }

  renderAvatars() {
    const peers = this.peers()
    avatars.replaceChildren(...peers.map((p) => avatar(p, p.agent ? false : p.name === me.name && p.color === me.color)))
    const mine = this.myAgent()
    inviteButton.hidden = !!mine
    if (!mine) inviteButton.querySelector("span").textContent = "Invite your agent"
  }

  // --- asks ---

  ask({ prompt, original, paragraph, from, to }) {
    const id = uid()
    this.doc.transact(() => {
      const ask = new Y.Map()
      this.asks.set(id, ask)
      for (const [key, value] of Object.entries({
        owner: me.id, askedBy: me.name, prompt, original, paragraph, from, to, status: "asked", createdAt: Date.now(),
      })) ask.set(key, value)
    }, "ask")
    if (!this.myAgent()) inviteAgent().catch(() => toast("Couldn't reach the server."))
  }

  update(id, fields) {
    const ask = this.asks.get(id)
    if (!ask) return
    this.doc.transact(() => {
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined) ask.delete(key)
        else ask.set(key, value)
      }
    }, "ask")
  }

  // Replaces the selected text with the proposal, in this browser, as an
  // ordinary edit the binding passes to the editor and the cable passes to
  // everyone else. Only the characters go; formatting markers and links in
  // the range stay, so the paragraph keeps its shape.
  accept(id) {
    const ask = this.asks.get(id)
    const range = ask && this.resolve(ask.get("from"), ask.get("to"))
    if (!range) return toast("The text this was for is gone.")

    const segments = this.textSegments(range)
    if (segments.length === 0) return toast("The text this was for is gone.")
    this.doc.transact(() => {
      for (const { child, start, length } of [...segments].reverse()) child.spliceText(start, length, "")
      segments[0].child.spliceText(segments[0].start, 0, ask.get("proposal") ?? "")
      ask.set("status", "accepted")
      ask.set("decidedBy", me.name)
    }, "accept")
  }

  // The text children of the block that hold [range.start, range.end), with
  // the part of each one inside it.
  textSegments({ type, start, end }) {
    const block = type._collabNode
    if (!block) return []
    const segments = []
    let offset = 0
    for (const child of block._children) {
      const size = child.getSize()
      if (typeof child.spliceText === "function") { // a text node
        const first = offset + (size - child._text.length) // past the node's marker
        const from = Math.max(start, first)
        const to = Math.min(end, offset + size)
        if (to > from) segments.push({ child, start: from - first, length: to - from })
      }
      offset += size
    }
    return segments
  }

  // Both ends of an ask, as absolute positions in one block, in order. Null
  // when either end is gone or they're in different blocks.
  resolve(fromJSON, toJSON) {
    try {
      const a = Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(fromJSON), this.doc)
      const b = Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(toJSON), this.doc)
      if (!a || !b || a.type !== b.type) return null
      return { type: a.type, start: Math.min(a.index, b.index), end: Math.max(a.index, b.index) }
    } catch {
      return null
    }
  }

  // The block's element on the page and a DOM Range over the asked-about
  // text, for the card's position and the highlight.
  locate(range) {
    const editor = this.editor
    const key = range?.type?._collabNode?._key
    const blockEl = key && editor?.getElementByKey(key)
    if (!blockEl) return null
    const segments = this.textSegments(range)
    let dom = null
    if (segments.length) {
      const first = segments[0]
      const last = segments[segments.length - 1]
      const startPoint = textPoint(editor.getElementByKey(first.child._key), first.start)
      const endPoint = textPoint(editor.getElementByKey(last.child._key), last.start + last.length)
      if (startPoint && endPoint) {
        dom = document.createRange()
        dom.setStart(...startPoint)
        dom.setEnd(...endPoint)
      }
    }
    return { blockEl, dom }
  }

  renderCards() {
    const highlights = []
    const seen = new Set()
    this.unspace()
    // Top to bottom, because a card's margin moves every paragraph under it.
    const placed = [...this.asks.entries()]
      .filter(([, ask]) => OPEN.has(ask.get("status")))
      .map(([id, ask]) => {
        const range = this.resolve(ask.get("from"), ask.get("to"))
        return { id, ask, where: range && this.locate(range) }
      })
      .filter(({ where }) => where)
      .sort((a, b) => a.where.blockEl === b.where.blockEl
        ? (a.ask.get("createdAt") ?? 0) - (b.ask.get("createdAt") ?? 0)
        : a.where.blockEl.compareDocumentPosition(b.where.blockEl) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1)

    for (const { id, ask, where } of placed) {
      seen.add(id)
      let card = this.cards.get(id)
      if (!card) {
        card = document.createElement("div")
        card.className = "ask-card"
        card.dataset.ask = id
        page.append(card)
        this.cards.set(id, card)
      }
      this.fillCard(card, id, ask)
      this.place(card, where.blockEl)
      if (where.dom) highlights.push(where.dom)
    }

    for (const [id, card] of this.cards) {
      if (!seen.has(id)) {
        card.remove()
        this.cards.delete(id)
      }
    }
    if (CSS.highlights) {
      if (highlights.length) CSS.highlights.set("yrby-ask", new Highlight(...highlights))
      else CSS.highlights.delete("yrby-ask")
    }
  }

  // A card sits under the paragraph it's about, and the paragraph gets a
  // bottom margin as tall as the card so nothing is covered.
  place(card, blockEl) {
    const pageBox = page.getBoundingClientRect()
    const extra = this.spaced.get(blockEl) ?? 0
    const top = blockEl.getBoundingClientRect().bottom - pageBox.top + extra + 10
    card.style.top = `${top}px`
    const height = card.offsetHeight + 22
    blockEl.style.marginBottom = `${extra + height}px`
    this.spaced.set(blockEl, extra + height)
  }

  unspace() {
    for (const blockEl of this.spaced.keys()) blockEl.style.marginBottom = ""
    this.spaced.clear()
  }

  fillCard(card, id, ask) {
    const status = ask.get("status")
    const owner = ask.get("owner")
    const agent = this.peers().find((p) => p.agent?.owner === owner)
    const agentName = `${ask.get("askedBy")}'s agent`
    const color = agent?.color ?? "#b8bfd3"
    const proposal = ask.get("proposal") ?? ""
    const key = [status, proposal, ask.get("error"), !!agent, card.classList.contains("revising")].join("\u0000")
    if (card.dataset.key === key) return
    card.dataset.key = key
    card.dataset.status = status
    card.style.setProperty("--agent", color)

    const head = el("div", "ask-head", [
      dot(color),
      el("span", "ask-agent", agentName),
      el("span", "ask-prompt", `“${ask.get("prompt")}”`),
    ])
    const parts = [head]

    if (proposal) parts.push(el("p", "ask-proposal", proposal))

    if (status === "asked" || status === "working") {
      const label = el("span", "working-label")
      label.dataset.started = String(this.startedAt(ask, agent) ?? "")
      label.dataset.waiting = agent ? "" : "true"
      label.textContent = this.workingText(label)
      const stop = button("stop", "Stop", () => this.update(id, { status: "stopped" }), "stop")
      stop.classList.add("working-stop")
      parts.push(el("div", "working-pill", [label, stop]))
    } else if (status === "proposed") {
      parts.push(el("div", "ask-bar", [
        button("ghost", "Undo", () => this.update(id, { status: "undone", decidedBy: me.name }), "undo"),
        button("ghost", "Ask for change", () => this.revise(card, id, ask), "chat"),
        button("accept", "Accept", () => this.accept(id), "check"),
      ]))
    } else if (status === "failed") {
      parts.push(el("p", "ask-error", `${agentName} couldn't answer: ${ask.get("error") ?? "something went wrong"}.`))
      parts.push(el("div", "ask-bar", [
        button("ghost", "Dismiss", () => this.update(id, { status: "undone" })),
        button("accept", "Try again", () => this.update(id, { status: "asked", error: undefined })),
      ]))
    }
    card.replaceChildren(...parts)
  }

  // A follow-up on a proposal: the same ask goes back to the agent with what
  // to change and the proposal it's about.
  revise(card, id, ask) {
    const bar = card.querySelector(".ask-bar")
    const form = requestForm("What should change?", (prompt) => {
      this.update(id, { prompt, previous: ask.get("proposal"), proposal: "", status: "asked" })
    }, () => form.replaceWith(bar))
    bar.replaceWith(form)
    form.querySelector("input").focus()
  }

  // The timer reads the agent's presence, which carries when it started. An
  // ask the agent hasn't claimed yet is waiting.
  startedAt(ask, agent) {
    return agent?.agent?.status === "working" ? agent.agent.startedAt : ask.get("startedAt")
  }

  workingText(label) {
    const started = Number(label.dataset.started)
    if (!started) return label.dataset.waiting ? "Waiting for the agent to join…" : "Working…"
    return `Working for ${Math.max(0, Math.floor((Date.now() - started) / 1000))}s`
  }

  tickTimers() {
    for (const label of page.querySelectorAll(".working-label")) label.textContent = this.workingText(label)
  }
}

// --- the selection toolbar --------------------------------------------------

// A floating "Ask for change" button over a selection in the editor. It
// takes the selection's ends from this browser's presence, where Lexical keeps
// them as Yjs relative positions, so they stay attached to the same characters
// while people keep typing.
class SelectionBar {
  constructor(session) {
    this.session = session
    this.bar = el("div", "selection-bar")
    this.bar.hidden = true
    this.askButton = button("ghost", "Ask for change", () => this.open(), "chat")
    this.bar.append(this.askButton)
    this.bar.addEventListener("mousedown", (event) => {
      if (event.target.tagName !== "INPUT") event.preventDefault() // keep the editor's selection
    })
    page.append(this.bar)
    this.onChange = () => { if (!this.form) this.follow() }
    document.addEventListener("selectionchange", this.onChange)
  }

  stop() {
    document.removeEventListener("selectionchange", this.onChange)
    this.bar.remove()
  }

  editorSelection() {
    const selection = getSelection()
    const content = page.querySelector(".lexxy-editor__content")
    if (!selection || selection.isCollapsed || !content?.contains(selection.anchorNode)) return null
    return selection
  }

  follow() {
    const selection = this.editorSelection()
    if (!selection) return void (this.bar.hidden = true)
    const box = selection.getRangeAt(0).getBoundingClientRect()
    const pageBox = page.getBoundingClientRect()
    this.bar.hidden = false
    this.bar.style.top = `${box.top - pageBox.top - this.bar.offsetHeight - 10}px`
    this.bar.style.left = `${Math.max(0, box.left - pageBox.left + box.width / 2 - this.bar.offsetWidth / 2)}px`
  }

  open() {
    const selection = this.editorSelection()
    const state = this.session.provider.awareness.getLocalState()
    if (!selection || !state?.anchorPos || !state?.focusPos) return
    // Every field, nulls included: the agent hands these back as its own
    // selection, and @lexical/yjs reads a missing field as present.
    const from = positionJSON(state.anchorPos)
    const to = positionJSON(state.focusPos)
    if (!this.session.resolve(from, to)) return toast("Select text inside one paragraph.")

    const original = selection.toString()
    const paragraph = markedParagraph(selection.getRangeAt(0))
    this.form = requestForm("Ask your agent to change this…", (prompt) => {
      this.session.ask({ prompt, original, paragraph, from, to })
      this.close()
    }, () => this.close())
    this.bar.replaceChildren(this.form)
    this.bar.classList.add("asking")
    this.form.querySelector("input").focus()
  }

  close() {
    this.form = null
    this.bar.classList.remove("asking")
    this.bar.replaceChildren(this.askButton)
    this.bar.hidden = true
  }
}

// --- small builders ---------------------------------------------------------

function el(tag, className, children) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (typeof children === "string") node.textContent = children
  else if (children) node.append(...children)
  return node
}

// Outline icons, drawn on a 24px grid.
const ICONS = {
  undo: "M9 14 4 9l5-5M4 9h10.5a5.5 5.5 0 0 1 0 11H11",
  chat: "M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-4-.9L3 20l1.1-4.2A8 8 0 0 1 3 11.5 8.6 8.6 0 0 1 12 3a8.6 8.6 0 0 1 9 8.5z",
  check: "M5 12.5 10 17l9-10",
  stop: "M8 8h8v8H8z",
  send: "M12 19V5M6 11l6-6 6 6",
}

function svgIcon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
  svg.setAttribute("viewBox", "0 0 24 24")
  svg.setAttribute("aria-hidden", "true")
  svg.classList.add("icon", `icon-${name}`)
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
  path.setAttribute("d", ICONS[name])
  svg.append(path)
  return svg
}

function button(kind, text, onClick, icon) {
  const node = el("button", `pill pill-${kind}`)
  node.type = "button"
  if (icon) node.append(svgIcon(icon))
  node.append(el("span", null, text))
  node.addEventListener("click", onClick)
  return node
}

function requestForm(placeholder, onSubmit, onCancel) {
  const input = el("input", "request-input")
  input.placeholder = placeholder
  input.maxLength = 300
  const send = el("button", "request-send")
  send.append(svgIcon("send"))
  send.type = "submit"
  send.setAttribute("aria-label", "Send")
  const form = el("form", "request-form", [input, send])
  form.addEventListener("submit", (event) => {
    event.preventDefault()
    const prompt = input.value.trim()
    if (prompt) onSubmit(prompt)
  })
  input.addEventListener("keydown", (event) => { if (event.key === "Escape") onCancel() })
  return form
}

// An agent is a ring, the way a dot is drawn before it's customized. A
// person is a circle with their initial.
function avatar(peer, isMe) {
  if (peer.agent) {
    const node = dot(peer.color)
    node.title = peer.name.split(" · ")[0]
    node.classList.toggle("is-working", peer.agent.status === "working")
    return node
  }
  const node = el("span", "avatar", peer.name.slice(0, 1))
  node.style.background = peer.color
  node.title = isMe ? `${peer.name} (you)` : peer.name
  return node
}

function dot(color) {
  const node = el("span", "agent-dot")
  node.style.setProperty("--agent", color)
  return node
}

// The paragraph around a selection, with the selection marked [[like this]],
// so the model writes a replacement that fits where the selection was.
function markedParagraph(range) {
  const block = range.startContainer.parentElement?.closest(".lexxy-editor__content > *")
  if (!block) return range.toString()
  const before = document.createRange()
  before.setStart(block, 0)
  before.setEnd(range.startContainer, range.startOffset)
  const after = document.createRange()
  after.setStart(range.endContainer, range.endOffset)
  after.setEnd(block, block.childNodes.length)
  return `${before.toString()}[[${range.toString()}]]${after.toString()}`
}

function positionJSON(position) {
  const { type = null, tname = null, item = null, assoc = 0 } = Y.relativePositionToJSON(position)
  return { type, tname, item, assoc }
}

// The DOM text node and offset `offset` characters into a Lexical text node's
// element.
function textPoint(element, offset) {
  if (!element) return null
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
  let node
  let last = null
  while ((node = walker.nextNode())) {
    last = node
    if (offset <= node.length) return [node, offset]
    offset -= node.length
  }
  return last ? [last, last.length] : [element, 0]
}

