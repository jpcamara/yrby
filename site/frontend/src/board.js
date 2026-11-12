// The agent board: a whiteboard where each person can bring an agent that
// draws. The page is /demos/board/:room, on the room's "board" document:
//
//   items   Y.Map of id -> Y.Map, one per thing on the board:
//             type    note | text | shape | path | connector | frame | sticker
//             x, y, w, h, z   board units; z orders items, frames below the rest
//             color   fill (a note, shape, or frame) or stroke (a path)
//             text    Y.Text: a note's title line and caption, a shape's or
//                     frame's label, a text item's words
//             icon    an emoji on a note, or a sticker's emoji, drawn as its
//                     illustration from /emoji/ when there is one
//             drawing what the agent asked its artist to draw for the item
//             art     that drawing once it's done, drawn in place of the icon,
//                     as JSON: { box: [x, y, w, h], shapes: [[tag, attrs, children]] }
//                     (app/agents/board_art.rb)
//             shape   rect | ellipse | pill, for a shape
//             points  a path's points, flat [x0, y0, x1, y1, ...] from (x, y):
//                     a Y.Array when someone draws it here, a plain array
//                     when the agent writes it
//             dash, stroke   a path's dashes and width
//             from, to       a connector's item ids
//             arrow          false for a connector with no arrowhead
//             by      who added it: a person's id, or "agent:<their id>"
//             ask     the ask that added it, for the ask's Undo
//   title, subtitle   Y.Text
//   asks    Y.Map of id -> Y.Map (app/agents/board_agent.rb has the fields)
//
// Pan and zoom belong to each window. Presence carries your name, color,
// cursor (in board units), and selection, and an agent adds "agent".
// Undo and redo only take back your own changes.
import "./board.css"
import * as Y from "yjs"
import { YrbyDocumentElement } from "yrby-client/element"
import { roomConsumer, setupRoomPage, uid, user } from "./room.js"

// --- who you are -------------------------------------------------------------

// Your agent belongs to you, so you keep your id, name, and color through a
// reload. sessionStorage is per tab, so a second window is a second person.
const me = (() => {
  try {
    const saved = JSON.parse(sessionStorage.getItem("yrby-board-person"))
    if (saved?.id) return saved
  } catch { /* storage blocked or empty */ }
  const fresh = { id: uid(), name: user.name, color: user.color }
  try { sessionStorage.setItem("yrby-board-person", JSON.stringify(fresh)) } catch { /* fine */ }
  return fresh
})()
user.name = me.name
user.color = me.color

YrbyDocumentElement.consumer = roomConsumer
setupRoomPage()

const LOCAL = { local: true } // the origin of this window's own edits, which undo tracks
const ASKING = "ask"          // the origin of ask bookkeeping and an ask's Undo
const NOTE_COLORS = ["#fde68a", "#bfdbfe", "#fbcfe8", "#bbf7d0", "#ddd6fe", "#fed7aa"]
const MIN_ZOOM = 0.15
const MAX_ZOOM = 3
const WRITE_EVERY = 40     // ms between writes while dragging or drawing
const PRESENCE_EVERY = 70  // ms between cursor updates
const OPEN_ASKS = new Set(["asked", "working", "done", "failed", "stopped"])

const $ = (selector) => document.querySelector(selector)

// Whether two JSON values are the same, ignoring key order.
const sameJSON = (a, b) => {
  if (a === b) return true
  if (typeof a !== "object" || typeof b !== "object" || !a || !b || Array.isArray(a) !== Array.isArray(b)) return false
  const keys = Object.keys(a)
  return keys.length === Object.keys(b).length && keys.every((key) => sameJSON(a[key], b[key]))
}

// A board item's Y.Map from its JSON, with its words as a Y.Text.
const itemFrom = (json) => {
  const item = new Y.Map()
  for (const [key, value] of Object.entries(json)) {
    item.set(key, key === "text" ? new Y.Text(String(value)) : value)
  }
  return item
}

// The card shows the start of what the agent said; the ask keeps all of it.
const firstSentence = (text) => text?.match(/^.*?[.!?](?=\s|$)/)?.[0] ?? text

const replaceText = (text, words) => {
  text.delete(0, text.length)
  if (words) text.insert(0, words)
}
const canvas = $("#board")
const world = canvas.querySelector(".board-world")
const statusLine = $("#status")

// --- small helpers -----------------------------------------------------------

function el(tag, className, children) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (typeof children === "string") node.textContent = children
  else if (children) node.append(...children.filter(Boolean))
  return node
}

function svg(tag, attrs = {}) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag)
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value)
  return node
}

function toast(text) {
  const node = $("#toast")
  node.textContent = text
  node.hidden = false
  clearTimeout(toast.timer)
  toast.timer = setTimeout(() => { node.hidden = true }, 4000)
}

// Draws an emoji as its illustration: Microsoft's Fluent flat art, which the
// build copies to /emoji/<codepoints>.svg. The files name each emoji by its
// full codepoints, with or without the U+FE0F variation selector, and a model
// may send either, so this tries both. An emoji with no art stays a character.
function setArt(node, icon, art) {
  const key = typeof art === "string" && art ? art : icon
  if (node.artKey === key) return
  node.artKey = key
  node.replaceChildren()
  const drawn = art && drawArt(art)
  if (drawn) return node.append(drawn)
  if (!icon) return
  const codes = [...icon].map((c) => c.codePointAt(0).toString(16))
  const bare = codes.filter((c) => c !== "fe0f")
  const names = [...new Set([codes, bare, [bare[0], "fe0f", ...bare.slice(1)]].map((c) => c.join("-")))]
  const img = el("img", "art")
  img.alt = icon
  img.draggable = false
  img.addEventListener("error", () => {
    const next = names.shift()
    if (next) img.src = `/emoji/${next}.svg`
    else img.replaceWith(el("span", "art-glyph", icon))
  })
  img.src = `/emoji/${names.shift()}.svg`
  node.append(img)
}

// A custom drawing, from shapes the server already checked. Anyone in the room
// can write an item's fields, so this builds only the same plain shapes and
// attributes again, and drops any value that could point somewhere.
const ART_TAGS = new Set(["g", "path", "circle", "ellipse", "rect", "polygon", "polyline", "line"])
const ART_ATTRS = new Set(["d", "cx", "cy", "r", "rx", "ry", "x", "y", "width", "height", "points", "x1", "y1",
  "x2", "y2", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "fill-rule", "opacity",
  "fill-opacity", "stroke-opacity", "transform"])

function drawArt(json) {
  let art
  try { art = JSON.parse(json) } catch { return null }
  if (!art || typeof art !== "object") return null
  const box = Array.isArray(art.box) && art.box.length === 4 && art.box.every(Number.isFinite) ? art.box : [0, 0, 100, 100]
  const root = svg("svg", { class: "art", viewBox: box.join(" "), "aria-hidden": "true" })
  let room = 200
  const add = (parent, shapes) => {
    for (const shape of Array.isArray(shapes) ? shapes : []) {
      const [tag, attrs, children] = Array.isArray(shape) ? shape : []
      if (!ART_TAGS.has(tag) || room-- <= 0) continue
      const node = svg(tag)
      for (const [key, value] of Object.entries(attrs || {})) {
        if (ART_ATTRS.has(key) && typeof value === "string" && !/url|[:;<>&\\]/i.test(value)) node.setAttribute(key, value)
      }
      if (tag === "g") add(node, children)
      parent.append(node)
    }
  }
  add(root, art.shapes)
  return root.childElementCount ? root : null
}

function isDark(hex) {
  const n = parseInt(String(hex || "#ffffff").slice(1), 16)
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255]
  return 0.299 * r + 0.587 * g + 0.114 * b < 140
}

function throttle(fn, ms) {
  let last = 0
  let timer = null
  return (...args) => {
    const wait = last + ms - Date.now()
    clearTimeout(timer)
    if (wait <= 0) {
      last = Date.now()
      fn(...args)
    } else {
      timer = setTimeout(() => { last = Date.now(); fn(...args) }, wait)
    }
  }
}

// A path's points as [[x, y], ...], from a Y.Array or a plain array.
function pointsOf(item) {
  const raw = item.get("points")
  const flat = raw instanceof Y.Array ? raw.toArray() : Array.isArray(raw) ? raw : []
  const points = []
  for (let i = 0; i + 1 < flat.length; i += 2) points.push([Number(flat[i]) || 0, Number(flat[i + 1]) || 0])
  return points
}

// A smooth curve through the points (Catmull-Rom, as cubic Béziers).
function smoothPath(points) {
  if (points.length === 0) return ""
  const [x0, y0] = points[0]
  if (points.length === 1) return `M${x0} ${y0}l0.1 0`
  let d = `M${x0} ${y0}`
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i - 1] ?? points[i]
    const p1 = points[i]
    const p2 = points[i + 1]
    const p3 = points[i + 2] ?? p2
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6]
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6]
    d += ` C${c1[0].toFixed(1)} ${c1[1].toFixed(1)} ${c2[0].toFixed(1)} ${c2[1].toFixed(1)} ${p2[0]} ${p2[1]}`
  }
  return d
}

// Where the line from a box's center toward (tx, ty) leaves the box.
function edgePoint(box, tx, ty) {
  const cx = box.x + box.w / 2
  const cy = box.y + box.h / 2
  const dx = tx - cx
  const dy = ty - cy
  if (dx === 0 && dy === 0) return [cx, cy]
  const scale = Math.min(Math.abs((box.w / 2 + 6) / (dx || 1e-9)), Math.abs((box.h / 2 + 6) / (dy || 1e-9)))
  return [cx + dx * Math.min(scale, 1), cy + dy * Math.min(scale, 1)]
}

// Keeps an <input> or <textarea> and a Y.Text the same. Typing becomes the
// smallest delete and insert, so two people typing in one note both keep
// their words, and a remote change keeps your caret where it was.
function bindText(doc, ytext, input) {
  input.value = ytext.toString()
  const onInput = () => {
    const before = ytext.toString()
    const after = input.value
    let start = 0
    while (start < before.length && start < after.length && before[start] === after[start]) start++
    let endBefore = before.length
    let endAfter = after.length
    while (endBefore > start && endAfter > start && before[endBefore - 1] === after[endAfter - 1]) {
      endBefore--
      endAfter--
    }
    doc.transact(() => {
      if (endBefore > start) ytext.delete(start, endBefore - start)
      if (endAfter > start) ytext.insert(start, after.slice(start, endAfter))
    }, LOCAL)
  }
  const onChange = (event, transaction) => {
    if (transaction.origin === LOCAL && transaction.local) return
    let [from, to] = [input.selectionStart ?? 0, input.selectionEnd ?? 0]
    let index = 0
    for (const op of event.delta) {
      if (op.retain) index += op.retain
      else if (op.insert) {
        const n = op.insert.length
        if (index <= from) from += n
        if (index <= to) to += n
        index += n
      } else if (op.delete) {
        if (index < from) from -= Math.min(op.delete, from - index)
        if (index < to) to -= Math.min(op.delete, to - index)
      }
    }
    input.value = ytext.toString()
    if (document.activeElement === input) input.setSelectionRange(from, to)
  }
  input.addEventListener("input", onInput)
  ytext.observe(onChange)
  return () => {
    input.removeEventListener("input", onInput)
    ytext.unobserve(onChange)
  }
}

// --- the agent --------------------------------------------------------------

// Why your agent couldn't come, as the reason on the ask's card.
const CANT_COME = {
  busy: "every agent seat is taken right now",
  limited: "you've invited an agent a lot this hour",
  refused: "it couldn't join this board",
  offline: "the server couldn't be reached",
}

// Asks the server to start your agent on this board. Returns null once it's
// coming or here, or why it can't (a CANT_COME key).
async function inviteAgent() {
  try {
    const query = new URLSearchParams({ owner: me.id, name: me.name, color: me.color })
    const response = await fetch(`${canvas.dataset.agentUrl}?${query}`, { method: "POST" })
    const json = response.headers.get("content-type")?.includes("json") ? await response.json() : {}
    if (json.status === "joining" || json.status === "here") return null
    return json.status === "busy" ? "busy" : response.status === 429 ? "limited" : "refused"
  } catch {
    return "offline"
  }
}

// --- the board ----------------------------------------------------------------

class Board {
  constructor({ doc, provider, lease }) {
    this.doc = doc
    this.provider = provider
    this.lease = lease
    this.items = doc.getMap("items")
    this.asks = doc.getMap("asks")
    this.title = doc.getText("title")
    this.subtitle = doc.getText("subtitle")
    this.undo = new Y.UndoManager([this.items, this.title, this.subtitle], { trackedOrigins: new Set([LOCAL]) })

    this.view = { x: 0, y: 0, s: 1 }
    this.tool = "select"
    this.selection = new Set()
    this.els = new Map()       // item id -> element
    this.cursors = new Map()   // client id -> cursor element
    this.cards = new Map()     // ask id -> card element
    this.presence = { user: { name: me.name, color: me.color, id: me.id }, cursor: null, selection: [] }
    this.stops = []

    this.frames = el("div", "layer layer-frames")
    this.layer = el("div", "layer layer-items")
    this.overlay = el("div", "layer layer-overlay")
    world.replaceChildren(this.frames, this.layer, this.overlay)
    this.handle = el("div", "resize-handle")
    this.handle.hidden = true
    this.overlay.append(this.handle)

    this.publish = throttle(() => this.lease.setPresence(this.presence), PRESENCE_EVERY)
    this.publishNow = () => this.lease.setPresence(this.presence)
    this.publishNow()
    // A reconnect clears this window's presence, so set it again.
    this.stops.push(provider.onStatusChange(({ status }) => {
      statusLine.dataset.state = status
      statusLine.textContent = status === "synced" ? "Saved" : status === "disconnected" ? "Offline" : "Connecting…"
      if (status !== "disconnected" && !provider.awareness.getLocalState()) this.publishNow()
    }))
    statusLine.textContent = provider.status === "synced" ? "Saved" : "Connecting…"

    const render = () => this.schedule()
    this.items.observeDeep(render)
    this.asks.observeDeep(render)
    provider.awareness.on("change", render)
    this.stops.push(() => this.items.unobserveDeep(render), () => this.asks.unobserveDeep(render),
      () => provider.awareness.off("change", render))
    const tick = setInterval(() => this.renderAsks(), 1000)
    this.stops.push(() => clearInterval(tick))

    this.stops.push(bindText(doc, this.title, $("#board-title")), bindText(doc, this.subtitle, $("#board-subtitle")))
    this.listen()
    this.fitOnce()
    this.applyView()
    this.render()
  }

  stop() {
    this.stops.forEach((stop) => stop())
    this.stopEditing()
    world.replaceChildren()
    this.undo.destroy()
  }

  // --- coordinates and view ---

  toWorld(clientX, clientY) {
    const box = canvas.getBoundingClientRect()
    return { x: (clientX - box.left - this.view.x) / this.view.s, y: (clientY - box.top - this.view.y) / this.view.s }
  }

  applyView() {
    const { x, y, s } = this.view
    world.style.transform = `translate(${x}px, ${y}px) scale(${s})`
    canvas.style.backgroundSize = `${32 * s}px ${32 * s}px`
    canvas.style.backgroundPosition = `${x}px ${y}px`
    canvas.style.setProperty("--zoom", s)
    $("#zoom-level").textContent = `${Math.round(s * 100)}%`
    for (const cursor of this.cursors.values()) cursor.style.setProperty("--inverse", 1 / s)
  }

  zoomAt(factor, clientX, clientY) {
    const box = canvas.getBoundingClientRect()
    const sx = clientX - box.left
    const sy = clientY - box.top
    const s = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, this.view.s * factor))
    this.view.x = sx - ((sx - this.view.x) * s) / this.view.s
    this.view.y = sy - ((sy - this.view.y) * s) / this.view.s
    this.view.s = s
    this.applyView()
  }

  // Shows the boxes, or everything on the board when none are given.
  fit(boxes = [...this.items.values()].map((item) => this.box(item)).filter(Boolean)) {
    if (boxes.length === 0) return
    const left = Math.min(...boxes.map((b) => b.x))
    const top = Math.min(...boxes.map((b) => b.y))
    const right = Math.max(...boxes.map((b) => b.x + b.w))
    const bottom = Math.max(...boxes.map((b) => b.y + b.h))
    const box = canvas.getBoundingClientRect()
    // Leave the asks panel on the right clear when it has cards.
    const panel = $("#asks").childElementCount ? Math.min(360, box.width / 3) : 0
    const width = box.width - 120 - panel
    const s = Math.min(1.2, Math.max(MIN_ZOOM, Math.min(width / (right - left), (box.height - 260) / (bottom - top))))
    this.view = { s, x: 60 + (width - (right - left) * s) / 2 - left * s, y: 120 + (box.height - 260 - (bottom - top) * s) / 2 - top * s }
    this.applyView()
  }

  fitOnce() {
    if (this.items.size > 0) this.fit()
    else this.view = { x: 60, y: 40, s: 1 }
  }

  // --- reading items ---

  box(item) {
    const type = item.get("type")
    if (type === "path") {
      const points = pointsOf(item)
      if (!points.length) return null
      const xs = points.map((p) => p[0])
      const ys = points.map((p) => p[1])
      return { x: item.get("x") + Math.min(...xs), y: item.get("y") + Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) }
    }
    if (type === "connector") return null
    return { x: Number(item.get("x")) || 0, y: Number(item.get("y")) || 0, w: Number(item.get("w")) || 0, h: Number(item.get("h")) || 0 }
  }

  text(item) {
    const text = item.get("text")
    return text instanceof Y.Text ? text.toString() : typeof text === "string" ? text : ""
  }

  topZ() {
    let z = 0
    this.items.forEach((item) => { z = Math.max(z, Number(item.get("z")) || 0) })
    return z
  }

  // --- writing items ---

  add(fields, { text } = {}) {
    const id = uid()
    this.undo.stopCapturing()
    this.doc.transact(() => {
      const item = new Y.Map()
      this.items.set(id, item)
      for (const [key, value] of Object.entries({ z: this.topZ() + 1, by: me.id, ...fields })) item.set(key, value)
      if (text !== undefined) item.set("text", new Y.Text(text))
    }, LOCAL)
    return id
  }

  remove(ids) {
    const gone = new Set(ids)
    // A connector goes with either end.
    this.items.forEach((item, id) => {
      if (item.get("type") === "connector" && (gone.has(item.get("from")) || gone.has(item.get("to")))) gone.add(id)
    })
    this.undo.stopCapturing()
    this.doc.transact(() => gone.forEach((id) => this.items.delete(id)), LOCAL)
    gone.forEach((id) => this.selection.delete(id))
    this.selectionChanged()
  }

  // --- rendering ---

  schedule() {
    if (this.pending) return
    this.pending = requestAnimationFrame(() => {
      this.pending = null
      this.render()
    })
  }

  render() {
    const peers = this.peers()
    const remoteSelections = new Map()
    for (const peer of peers) {
      if (peer.self) continue
      for (const id of peer.selection ?? []) remoteSelections.set(id, peer.user.color)
    }

    for (const [id, node] of this.els) {
      if (!this.items.has(id)) {
        node.remove()
        this.els.delete(id)
        this.selection.delete(id)
      }
    }
    this.items.forEach((item, id) => {
      const type = item.get("type")
      let node = this.els.get(id)
      if (node && node.dataset.type !== type) {
        node.remove()
        node = null
      }
      if (!node) {
        node = this.create(type, id)
        if (!node) return
        ;(type === "frame" ? this.frames : this.layer).append(node)
        this.els.set(id, node)
      }
      this.draw(node, item)
      node.classList.toggle("is-selected", this.selection.has(id))
      const remote = remoteSelections.get(id)
      node.classList.toggle("is-peer-selected", !!remote && !this.selection.has(id))
      if (remote) node.style.setProperty("--peer", remote)
    })
    this.placeHandle()
    this.renderCursors(peers)
    this.renderAvatars(peers)
    this.renderAsks()
  }

  create(type, id) {
    let node
    switch (type) {
      case "note":
        node = el("div", "item note", [el("div", "note-icon"), el("div", "note-title"), el("div", "note-caption")])
        break
      case "text":
        node = el("div", "item text-item")
        break
      case "shape":
        node = el("div", "item shape", [el("span", "shape-label")])
        break
      case "frame":
        node = el("div", "item frame", [el("div", "frame-label")])
        break
      case "sticker":
        node = el("div", "item sticker")
        break
      case "path":
      case "connector": {
        node = svg("svg", { class: `item ${type}` })
        node.append(svg("path", { class: "hit" }), svg("path", { class: "line" }))
        if (type === "connector") node.append(svg("path", { class: "arrow" }))
        break
      }
      default:
        return null
    }
    node.dataset.id = id
    node.dataset.type = type
    return node
  }

  draw(node, item) {
    const type = item.get("type")
    const color = item.get("color")
    const z = Number(item.get("z")) || 0
    node.style.zIndex = String(Math.round(z) + (type === "frame" ? 0 : 100000))
    node.classList.toggle("is-agent", String(item.get("by") ?? "").startsWith("agent:"))
    if (type === "path") return this.drawPath(node, item)
    if (type === "connector") return this.drawConnector(node, item)

    const { x, y, w, h } = this.box(item)
    node.style.left = `${x}px`
    node.style.top = `${y}px`
    node.style.width = `${w}px`
    node.style.height = `${h}px`
    const words = this.text(item)
    if (this.editing?.node === node) return

    if (type === "note") {
      node.style.background = color || NOTE_COLORS[0]
      const [first, ...rest] = words.split("\n")
      const art = item.get("art")
      setArt(node.children[0], item.get("icon") ?? "", art)
      node.children[0].hidden = !item.get("icon") && !art
      node.classList.toggle("has-art", Boolean(item.get("icon") || art))
      node.children[1].textContent = first
      node.children[2].textContent = rest.join("\n")
    } else if (type === "text") {
      node.textContent = words
      node.style.fontSize = `${Number(item.get("size")) || 18}px`
      node.style.textAlign = item.get("align") || "left"
      node.classList.toggle("is-heading", (Number(item.get("size")) || 18) >= 26)
    } else if (type === "shape") {
      node.dataset.shape = item.get("shape") || "rect"
      node.style.background = color || "#ffffff"
      node.classList.toggle("is-dark", isDark(color))
      node.children[0].textContent = words
    } else if (type === "frame") {
      node.style.setProperty("--frame", color || "#e5e7eb")
      node.children[0].textContent = words || "Frame"
    } else if (type === "sticker") {
      setArt(node, item.get("icon") || "⭐", item.get("art"))
      node.style.fontSize = `${Math.round(h * 0.8)}px`
    }
  }

  drawPath(node, item) {
    const ox = Number(item.get("x")) || 0
    const oy = Number(item.get("y")) || 0
    const points = pointsOf(item)
    const stroke = Number(item.get("stroke")) || 3
    const pad = stroke + 12
    const xs = points.map((p) => p[0])
    const ys = points.map((p) => p[1])
    const left = (xs.length ? Math.min(...xs) : 0) - pad
    const top = (ys.length ? Math.min(...ys) : 0) - pad
    const w = (xs.length ? Math.max(...xs) : 0) - left + pad
    const h = (ys.length ? Math.max(...ys) : 0) - top + pad
    this.placeSvg(node, ox + left, oy + top, w, h, left, top)
    const d = smoothPath(points)
    for (const path of node.querySelectorAll("path")) path.setAttribute("d", d)
    const line = node.querySelector(".line")
    line.setAttribute("stroke", item.get("color") || "#1f2937")
    line.setAttribute("stroke-width", stroke)
    line.setAttribute("stroke-dasharray", item.get("dash") ? `${stroke * 3} ${stroke * 3}` : "none")
  }

  drawConnector(node, item) {
    const from = this.items.get(item.get("from"))
    const to = this.items.get(item.get("to"))
    const a = from && this.box(from)
    const b = to && this.box(to)
    if (!a || !b) return void (node.style.display = "none")
    node.style.display = ""
    const [x1, y1] = edgePoint(a, b.x + b.w / 2, b.y + b.h / 2)
    const [x2, y2] = edgePoint(b, a.x + a.w / 2, a.y + a.h / 2)
    const left = Math.min(x1, x2) - 16
    const top = Math.min(y1, y2) - 16
    this.placeSvg(node, left, top, Math.abs(x2 - x1) + 32, Math.abs(y2 - y1) + 32, left, top)
    const d = `M${x1} ${y1}L${x2} ${y2}`
    node.querySelector(".hit").setAttribute("d", d)
    node.querySelector(".line").setAttribute("d", d)
    const angle = Math.atan2(y2 - y1, x2 - x1)
    const tip = (da) => `${x2 - 12 * Math.cos(angle + da)} ${y2 - 12 * Math.sin(angle + da)}`
    const arrow = item.get("arrow") !== false
    node.querySelector(".arrow").setAttribute("d", arrow ? `M${tip(0.45)}L${x2} ${y2}L${tip(-0.45)}` : "")
    node.style.setProperty("--stroke", item.get("color") || "#475569")
  }

  placeSvg(node, x, y, w, h, viewX, viewY) {
    node.style.left = `${x}px`
    node.style.top = `${y}px`
    node.setAttribute("width", Math.max(1, w))
    node.setAttribute("height", Math.max(1, h))
    node.setAttribute("viewBox", `${viewX} ${viewY} ${Math.max(1, w)} ${Math.max(1, h)}`)
  }

  placeHandle() {
    const [id] = this.selection
    const item = this.selection.size === 1 && this.items.get(id)
    const resizable = item && ["note", "text", "shape", "frame", "sticker"].includes(item.get("type"))
    this.handle.hidden = !resizable
    if (!resizable) return
    const { x, y, w, h } = this.box(item)
    this.handle.style.left = `${x + w}px`
    this.handle.style.top = `${y + h}px`
  }

  // --- people ---

  peers() {
    const self = this.provider.awareness.clientID
    return [...this.provider.awareness.getStates().entries()]
      .filter(([, state]) => state?.user?.name)
      .map(([id, state]) => ({ id, self: id === self, ...state }))
  }

  myAgent() { return this.peers().find((peer) => peer.agent?.owner === me.id) }

  renderCursors(peers) {
    const seen = new Set()
    for (const peer of peers) {
      if (peer.self || !peer.cursor) continue
      seen.add(peer.id)
      let cursor = this.cursors.get(peer.id)
      if (!cursor) {
        const arrow = svg("svg", { viewBox: "0 0 20 20", class: "cursor-arrow" })
        arrow.append(svg("path", { d: "M2 2l6.5 16 2.3-6.7L17.5 9z" }))
        cursor = el("div", "cursor", [arrow, el("span", "cursor-name")])
        cursor.style.setProperty("--inverse", 1 / this.view.s)
        this.overlay.append(cursor)
        this.cursors.set(peer.id, cursor)
      }
      cursor.classList.toggle("is-agent", !!peer.agent)
      cursor.classList.toggle("is-working", peer.agent?.status === "working")
      cursor.style.setProperty("--color", peer.user.color)
      cursor.style.setProperty("--x", `${peer.cursor.x}px`)
      cursor.style.setProperty("--y", `${peer.cursor.y}px`)
      const label = peer.agent ? `✦ ${peer.user.name}${peer.agent.status === "working" ? " · drawing" : ""}` : peer.user.name
      if (cursor.lastChild.textContent !== label) cursor.lastChild.textContent = label
    }
    for (const [id, cursor] of this.cursors) {
      if (!seen.has(id)) {
        cursor.remove()
        this.cursors.delete(id)
      }
    }
  }

  renderAvatars(peers) {
    const avatars = $("#avatars")
    const key = peers.map((p) => `${p.id}:${p.user.name}:${p.user.color}:${p.agent?.status ?? ""}`).join("|")
    if (avatars.dataset.key === key) return
    avatars.dataset.key = key
    avatars.replaceChildren(...peers.map((peer) => {
      if (peer.agent) {
        const ring = el("span", `avatar is-agent${peer.agent.status === "working" ? " is-working" : ""}`, "✦")
        ring.style.setProperty("--color", peer.user.color)
        ring.title = peer.user.name
        return ring
      }
      const face = el("span", "avatar", peer.user.name.slice(0, 1))
      face.style.setProperty("--color", peer.user.color)
      face.title = peer.self ? `${peer.user.name} (you)` : peer.user.name
      return face
    }))
  }

  // --- asks ---

  ask(prompt) {
    const id = uid()
    const box = canvas.getBoundingClientRect()
    const at = this.toWorld(box.left + 80, box.top + 150)
    // What they can see, in board units, less the title, the toolbar, and
    // the asks panel on the right, where this ask's card is about to appear.
    const panel = Math.min(360, box.width / 3)
    const topLeft = this.toWorld(box.left + 40, box.top + 110)
    const bottomRight = this.toWorld(box.right - panel, box.bottom - 100)
    this.doc.transact(() => {
      const ask = new Y.Map()
      this.asks.set(id, ask)
      for (const [key, value] of Object.entries({
        owner: me.id, askedBy: me.name, color: me.color, prompt, status: "asked", createdAt: Date.now(),
        at: { x: Math.round(at.x), y: Math.round(at.y) },
        view: { x: Math.round(topLeft.x), y: Math.round(topLeft.y),
                w: Math.round(bottomRight.x - topLeft.x), h: Math.round(bottomRight.y - topLeft.y) },
      })) ask.set(key, value)
    }, ASKING)
    this.summon(id)
  }

  // An ask needs your agent. When it can't come, the ask fails with why.
  async summon(id) {
    if (this.myAgent()) return
    const problem = await inviteAgent()
    if (problem) this.updateAsk(id, { status: "failed", error: CANT_COME[problem] })
  }

  // Asking again makes the ask yours, so your agent answers it, even when
  // someone else asked first.
  askAgain(id, fields) {
    this.updateAsk(id, { ...fields, owner: me.id, askedBy: me.name, color: me.color, status: "asked" })
    this.summon(id)
  }

  updateAsk(id, fields) {
    const ask = this.asks.get(id)
    if (!ask) return
    this.doc.transact(() => {
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined) ask.delete(key)
        else ask.set(key, value)
      }
    }, ASKING)
  }

  askItems(id) {
    const ids = []
    this.items.forEach((item, key) => { if (item.get("ask") === id) ids.push(key) })
    return ids
  }

  // Takes the ask back: removes what it added, and puts back what it changed
  // or deleted, and the title it set. Anything someone changed since the
  // agent did stays as they left it. Anyone can.
  undoAsk(id) {
    const ask = this.asks.get(id)
    let kept = 0
    this.doc.transact(() => {
      for (const key of this.askItems(id)) this.items.delete(key)
      const after = ask?.get("after")
      ask?.get("before")?.forEach((was, key) => {
        const left = after?.get(key)
        const now = this.items.get(key)
        if (!sameJSON(now ? now.toJSON() : null, left ? JSON.parse(left) : null)) { kept++; return }
        this.items.set(key, itemFrom(JSON.parse(was)))
      })
      const titleBefore = ask?.get("titleBefore")
      if (titleBefore) {
        if (sameJSON([this.title.toString(), this.subtitle.toString()], JSON.parse(ask.get("titleAfter") ?? "null"))) {
          const [title, subtitle] = JSON.parse(titleBefore)
          replaceText(this.title, title)
          replaceText(this.subtitle, subtitle)
        } else kept++
      } else if (ask?.get("titled")) {
        this.title.delete(0, this.title.length)
        this.subtitle.delete(0, this.subtitle.length)
      }
      ask?.set("status", "undone")
      ask?.set("decidedBy", me.name)
      if (kept) ask?.set("kept", kept)
    }, ASKING)
  }

  renderAsks() {
    const panel = $("#asks")
    const open = [...this.asks.entries()]
      .filter(([, ask]) => OPEN_ASKS.has(ask.get("status")) && !ask.get("closed"))
      .sort(([, a], [, b]) => (b.get("createdAt") ?? 0) - (a.get("createdAt") ?? 0))
      .slice(0, 6)
    const seen = new Set()
    for (const [id, ask] of open) {
      seen.add(id)
      let card = this.cards.get(id)
      if (!card) {
        card = el("div", "ask-card")
        card.dataset.ask = id
        this.cards.set(id, card)
      }
      this.fillCard(card, id, ask)
    }
    for (const [id, card] of this.cards) {
      if (!seen.has(id)) {
        card.remove()
        this.cards.delete(id)
      }
    }
    const order = open.map(([id]) => this.cards.get(id))
    if (order.some((card, i) => panel.children[i] !== card) || panel.children.length !== order.length) panel.replaceChildren(...order)
  }

  fillCard(card, id, ask) {
    // Leave the card alone while someone types a change into it.
    if (card.classList.contains("is-revising")) return
    const status = ask.get("status")
    const owner = ask.get("owner")
    const agent = this.peers().find((peer) => peer.agent?.owner === owner)
    const color = agent?.user.color ?? ask.get("color") ?? "#94a3b8"
    const drawn = Number(ask.get("drawn")) || 0
    const started = Number(ask.get("startedAt")) || 0
    const seconds = started ? Math.max(0, Math.floor((Date.now() - started) / 1000)) : 0
    const key = [status, drawn, ask.get("error"), ask.get("plan"), ask.get("activity"), !!agent, status === "working" ? seconds : ""].join("\u0000")
    if (card.dataset.key === key) return
    card.dataset.key = key
    card.dataset.status = status
    card.style.setProperty("--color", color)

    const line = {
      asked: agent ? "Reading the board…" : "Waiting for the agent to join…",
      working: `${ask.get("activity") || "Working"} · ${drawn} ${drawn === 1 ? "change" : "changes"} · ${seconds}s`,
      done: firstSentence(ask.get("plan")) || `Made ${drawn} ${drawn === 1 ? "change" : "changes"}`,
      stopped: `Stopped after ${drawn} ${drawn === 1 ? "change" : "changes"}`,
      failed: `Couldn't draw it: ${ask.get("error") ?? "something went wrong"}.`,
    }[status]

    const close = this.button("×", () => this.updateAsk(id, { closed: true }), "ask-close")
    close.title = "Hide"
    const parts = [
      el("div", "ask-head", [el("span", "ask-dot"), el("span", "ask-agent", `${ask.get("askedBy")}'s agent`), close]),
      el("p", "ask-prompt", ask.get("prompt")),
      el("p", "ask-line", line),
    ]
    const actions = []
    if (status === "asked" || status === "working") {
      actions.push(this.button("Stop", () => this.updateAsk(id, { status: "stopped" })))
    } else if (status === "done" || status === "stopped") {
      actions.push(this.button("Show", () => this.fit(this.askItems(id).map((key) => this.box(this.items.get(key))).filter(Boolean))))
      actions.push(this.button("Undo", () => this.undoAsk(id), "is-undo"))
      actions.push(this.button("Ask for a change", () => this.revise(card, id, ask), "is-primary"))
    } else if (status === "failed") {
      actions.push(this.button("Try again", () => this.askAgain(id, { error: undefined }), "is-primary"))
    }
    if (actions.length) parts.push(el("div", "ask-actions", actions))
    card.replaceChildren(...parts)
  }

  revise(card, id, ask) {
    card.classList.add("is-revising")
    const input = el("input", "ask-change")
    input.placeholder = "What should change?"
    input.maxLength = 300
    const form = el("form", "ask-change-form", [input])
    form.addEventListener("submit", (event) => {
      event.preventDefault()
      const prompt = input.value.trim()
      if (!prompt) return
      card.classList.remove("is-revising")
      this.askAgain(id, { earlier: ask.get("prompt"), previous: ask.get("plan") ?? "", prompt, drawn: 0 })
    })
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        card.classList.remove("is-revising")
        card.dataset.key = ""
        this.renderAsks()
      }
    })
    card.querySelector(".ask-actions")?.replaceWith(form)
    input.focus()
  }

  button(text, onClick, className = "") {
    const node = el("button", `ask-button ${className}`, text)
    node.type = "button"
    node.addEventListener("click", onClick)
    return node
  }

  // --- selection and tools ---

  select(ids) {
    this.selection = new Set(ids)
    this.selectionChanged()
  }

  selectionChanged() {
    this.presence.selection = [...this.selection]
    this.publish()
    this.schedule()
  }

  setTool(tool) {
    this.tool = tool
    canvas.dataset.tool = tool
    for (const button of document.querySelectorAll("[data-tool]")) button.classList.toggle("is-active", button.dataset.tool === tool)
  }

  // --- editing text ---

  startEditing(id) {
    this.stopEditing()
    const item = this.items.get(id)
    const node = this.els.get(id)
    if (!item || !node || !["note", "text", "shape", "frame"].includes(item.get("type"))) return
    if (!(item.get("text") instanceof Y.Text)) {
      this.doc.transact(() => item.set("text", new Y.Text(this.text(item))), LOCAL)
    }
    const input = el("textarea", `editor editor-${item.get("type")}`)
    input.spellcheck = false
    const box = this.box(item)
    if (item.get("type") === "frame") Object.assign(box, { h: 34 })
    Object.assign(input.style, { left: `${box.x}px`, top: `${box.y}px`, width: `${box.w}px`, height: `${box.h}px` })
    if (item.get("type") === "note") input.style.background = item.get("color") || NOTE_COLORS[0]
    if (item.get("type") === "text") input.style.fontSize = `${Number(item.get("size")) || 18}px`
    this.overlay.append(input)
    node.classList.add("is-editing")
    const unbind = bindText(this.doc, item.get("text"), input)
    this.editing = { id, node, input, unbind }
    input.addEventListener("blur", () => this.stopEditing())
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault()
        this.stopEditing()
      }
    })
    input.focus()
    input.setSelectionRange(input.value.length, input.value.length)
  }

  stopEditing() {
    const editing = this.editing
    if (!editing) return
    this.editing = null
    editing.unbind()
    editing.input.remove()
    editing.node.classList.remove("is-editing")
    const item = this.items.get(editing.id)
    if (item?.get("type") === "text" && !this.text(item).trim()) this.remove([editing.id])
    this.schedule()
  }

  // --- input ---

  listen() {
    const on = (target, type, handler, options) => {
      target.addEventListener(type, handler, options)
      this.stops.push(() => target.removeEventListener(type, handler, options))
    }
    on(canvas, "pointerdown", (event) => this.pointerDown(event))
    on(canvas, "pointermove", (event) => this.pointerMove(event))
    on(canvas, "pointerup", (event) => this.pointerUp(event))
    on(canvas, "pointercancel", (event) => this.pointerUp(event))
    on(canvas, "pointerleave", () => {
      this.presence.cursor = null
      this.publish()
    })
    on(canvas, "dblclick", (event) => this.doubleClick(event))
    on(canvas, "wheel", (event) => this.wheel(event), { passive: false })
    on(document, "keydown", (event) => this.key(event))
    on(window, "resize", () => this.applyView())

    for (const button of document.querySelectorAll("[data-tool]")) {
      on(button, "click", () => this.setTool(button.dataset.tool))
    }
    for (const button of document.querySelectorAll("[data-zoom]")) {
      on(button, "click", () => {
        const box = canvas.getBoundingClientRect()
        if (button.dataset.zoom === "fit") this.fit()
        else this.zoomAt(button.dataset.zoom === "in" ? 1.2 : 1 / 1.2, box.left + box.width / 2, box.top + box.height / 2)
      })
    }
    on($("#ask-agent"), "click", () => this.toggleAskBox())
    on($("#ask-box"), "submit", (event) => {
      event.preventDefault()
      const input = $("#ask-input")
      const prompt = input.value.trim().replace(/^@agent\s*/i, "") || input.placeholder
      input.value = ""
      this.toggleAskBox(false)
      this.ask(prompt)
    })
    on($("#ask-input"), "keydown", (event) => { if (event.key === "Escape") this.toggleAskBox(false) })
    on($("#share"), "click", async () => {
      try {
        await navigator.clipboard.writeText(location.href)
        toast("Link copied. Anyone with it can join this board.")
      } catch {
        toast("Copy the address bar to share this board.")
      }
    })
  }

  toggleAskBox(show) {
    const box = $("#ask-box")
    box.hidden = show === undefined ? !box.hidden : !show
    $("#ask-agent").classList.toggle("is-active", !box.hidden)
    if (!box.hidden) $("#ask-input").focus()
  }

  itemAt(event) {
    const node = event.target.closest?.(".item")
    return node && this.items.has(node.dataset.id) ? node.dataset.id : null
  }

  pointerDown(event) {
    if (event.target.closest(".editor")) return
    // No mousedown, so the browser doesn't move focus after a tool opens a
    // note for typing. The canvas takes focus for the shortcuts instead.
    event.preventDefault()
    if (this.editing) this.stopEditing()
    canvas.focus({ preventScroll: true })
    const at = this.toWorld(event.clientX, event.clientY)
    const id = this.itemAt(event)
    const start = { x: event.clientX, y: event.clientY, at }
    canvas.setPointerCapture(event.pointerId)

    if (event.button === 1 || this.spaceDown) {
      this.drag = { kind: "pan", start, view: { ...this.view } }
      return
    }
    if (event.target === this.handle) {
      const [selected] = this.selection
      const item = this.items.get(selected)
      this.undo.stopCapturing()
      this.drag = { kind: "resize", id: selected, start, box: this.box(item), type: item.get("type") }
      return
    }

    switch (this.tool) {
      case "pen": {
        this.undo.stopCapturing()
        const points = new Y.Array()
        points.push([0, 0])
        const strokeId = this.add({ type: "path", x: Math.round(at.x), y: Math.round(at.y), points, color: "#1f2937", stroke: 3 })
        this.drag = { kind: "pen", id: strokeId, points, origin: at, buffer: [], last: at }
        return
      }
      case "note":
      case "text":
      case "shape": {
        const fields = {
          note: { type: "note", w: 200, h: 132, color: NOTE_COLORS[Math.floor(Math.random() * NOTE_COLORS.length)] },
          text: { type: "text", w: 240, h: 32, size: 18 },
          shape: { type: "shape", shape: "rect", w: 160, h: 96, color: "#ffffff" },
        }[this.tool]
        const created = this.add({ ...fields, x: Math.round(at.x - fields.w / 2), y: Math.round(at.y - fields.h / 2) }, { text: "" })
        const tool = this.tool
        this.setTool("select")
        this.select([created])
        this.render()
        if (tool !== "shape") this.startEditing(created)
        return
      }
      case "connector":
        if (id) {
          const line = svg("svg", { class: "connector-preview" })
          line.append(svg("path"))
          this.overlay.append(line)
          this.drag = { kind: "connect", from: id, line }
        }
        return
    }

    // select
    if (!id) {
      if (!event.shiftKey) this.select([])
      this.drag = { kind: "pan", start, view: { ...this.view } }
      return
    }
    if (event.shiftKey) {
      const next = new Set(this.selection)
      next.has(id) ? next.delete(id) : next.add(id)
      this.select(next)
    } else if (!this.selection.has(id)) {
      this.select([id])
    }
    // Moving a frame moves what's inside it.
    const moving = new Set(this.selection)
    for (const selected of this.selection) {
      const item = this.items.get(selected)
      if (item?.get("type") !== "frame") continue
      const f = this.box(item)
      this.items.forEach((other, key) => {
        const b = this.box(other)
        if (b && key !== selected && b.x >= f.x && b.y >= f.y && b.x + b.w <= f.x + f.w && b.y + b.h <= f.y + f.h) moving.add(key)
      })
    }
    const origins = new Map()
    for (const key of moving) {
      const item = this.items.get(key)
      if (item && item.get("type") !== "connector") origins.set(key, { x: Number(item.get("x")) || 0, y: Number(item.get("y")) || 0 })
    }
    this.undo.stopCapturing()
    this.drag = { kind: "move", start, origins, pending: null }
  }

  pointerMove(event) {
    const at = this.toWorld(event.clientX, event.clientY)
    this.presence.cursor = { x: Math.round(at.x), y: Math.round(at.y) }
    this.publish()
    const drag = this.drag
    if (!drag) return

    if (drag.kind === "pan") {
      this.view.x = drag.view.x + event.clientX - drag.start.x
      this.view.y = drag.view.y + event.clientY - drag.start.y
      this.applyView()
    } else if (drag.kind === "move") {
      const dx = at.x - drag.start.at.x
      const dy = at.y - drag.start.at.y
      drag.moved = true
      drag.pending = { dx, dy }
      this.flushMove ??= throttle(() => this.writeMove(), WRITE_EVERY)
      this.flushMove()
    } else if (drag.kind === "resize") {
      const w = Math.max(40, Math.round(drag.box.w + at.x - drag.start.at.x))
      const h = Math.max(drag.type === "text" ? 24 : 40, Math.round(drag.box.h + at.y - drag.start.at.y))
      drag.pending = { w, h }
      this.flushResize ??= throttle(() => this.writeResize(), WRITE_EVERY)
      this.flushResize()
    } else if (drag.kind === "pen") {
      const last = drag.last
      if (Math.hypot(at.x - last.x, at.y - last.y) < 3 / this.view.s) return
      drag.last = at
      drag.buffer.push(Math.round(at.x - drag.origin.x), Math.round(at.y - drag.origin.y))
      this.flushPen ??= throttle(() => this.writePen(), WRITE_EVERY)
      this.flushPen()
    } else if (drag.kind === "connect") {
      const from = this.box(this.items.get(drag.from))
      if (!from) return
      const [x1, y1] = edgePoint(from, at.x, at.y)
      const left = Math.min(x1, at.x) - 4
      const top = Math.min(y1, at.y) - 4
      this.placeSvg(drag.line, left, top, Math.abs(at.x - x1) + 8, Math.abs(at.y - y1) + 8, left, top)
      drag.line.firstChild.setAttribute("d", `M${x1} ${y1}L${at.x} ${at.y}`)
    }
  }

  writeMove() {
    const drag = this.drag
    if (drag?.kind !== "move" || !drag.pending) return
    const { dx, dy } = drag.pending
    drag.pending = null
    this.doc.transact(() => {
      for (const [key, origin] of drag.origins) {
        const item = this.items.get(key)
        if (!item) continue
        item.set("x", Math.round(origin.x + dx))
        item.set("y", Math.round(origin.y + dy))
      }
    }, LOCAL)
  }

  writeResize() {
    const drag = this.drag
    if (drag?.kind !== "resize" || !drag.pending) return
    const item = this.items.get(drag.id)
    const { w, h } = drag.pending
    drag.pending = null
    if (item) this.doc.transact(() => { item.set("w", w); item.set("h", h) }, LOCAL)
  }

  writePen() {
    const drag = this.drag
    if (drag?.kind !== "pen" || drag.buffer.length === 0) return
    const points = drag.buffer.splice(0)
    this.doc.transact(() => drag.points.push(points), LOCAL)
  }

  pointerUp(event) {
    const drag = this.drag
    if (!drag) return
    if (drag.kind === "move") this.writeMove()
    if (drag.kind === "resize") this.writeResize()
    if (drag.kind === "pen") {
      this.writePen()
      // The box, for the agent to keep clear of.
      const item = this.items.get(drag.id)
      const box = item && this.box(item)
      if (box) this.doc.transact(() => { item.set("w", Math.round(box.w)); item.set("h", Math.round(box.h)) }, LOCAL)
      this.undo.stopCapturing()
    }
    if (drag.kind === "connect") {
      drag.line.remove()
      const target = document.elementFromPoint(event.clientX, event.clientY)?.closest?.(".item")?.dataset.id
      if (target && target !== drag.from && this.items.get(target)?.get("type") !== "connector") {
        this.add({ type: "connector", from: drag.from, to: target, color: "#475569" })
        this.setTool("select")
      }
    }
    this.drag = null
  }

  doubleClick(event) {
    if (event.target.closest(".editor")) return
    const id = this.itemAt(event)
    if (id) return this.startEditing(id)
    if (this.tool !== "select") return
    const at = this.toWorld(event.clientX, event.clientY)
    const created = this.add({ type: "note", x: Math.round(at.x - 100), y: Math.round(at.y - 66), w: 200, h: 132, color: NOTE_COLORS[0] }, { text: "" })
    this.select([created])
    this.render()
    this.startEditing(created)
  }

  wheel(event) {
    event.preventDefault()
    if (event.ctrlKey || event.metaKey) {
      // A pinch sends small steps and a wheel big ones, so a step is capped.
      this.zoomAt(Math.exp(-Math.max(-40, Math.min(40, event.deltaY)) * 0.01), event.clientX, event.clientY)
    } else {
      this.view.x -= event.deltaX
      this.view.y -= event.deltaY
      this.applyView()
    }
  }

  key(event) {
    const typing = event.target.closest?.("input, textarea")
    const mod = event.metaKey || event.ctrlKey
    if (mod && event.key.toLowerCase() === "z" && (!typing || this.editing?.input === event.target)) {
      event.preventDefault()
      event.shiftKey ? this.undo.redo() : this.undo.undo()
      return
    }
    if (mod && event.key.toLowerCase() === "y" && !typing) {
      event.preventDefault()
      this.undo.redo()
      return
    }
    if (typing) return
    if (event.key === " ") {
      this.spaceDown = true
      const up = (e) => { if (e.key === " ") { this.spaceDown = false; document.removeEventListener("keyup", up) } }
      document.addEventListener("keyup", up)
      return
    }
    if ((event.key === "Delete" || event.key === "Backspace") && this.selection.size) {
      event.preventDefault()
      return this.remove([...this.selection])
    }
    if (event.key === "Escape") {
      this.select([])
      this.setTool("select")
      return this.toggleAskBox(false)
    }
    if (event.key === "Enter" && this.selection.size === 1) {
      event.preventDefault()
      return this.startEditing([...this.selection][0])
    }
    if (mod || event.altKey) return
    const tool = { v: "select", p: "pen", t: "text", n: "note", s: "shape", c: "connector" }[event.key.toLowerCase()]
    if (tool) return this.setTool(tool)
    if (event.key.toLowerCase() === "a") {
      event.preventDefault()
      this.toggleAskBox(true)
    }
  }
}

// --- the document session ---------------------------------------------------

document.addEventListener("yrby:synced", ({ detail }) => {
  const board = new Board(detail)
  window.__board = { board, ydoc: detail.doc, provider: detail.provider, me }
  detail.signal.addEventListener("abort", () => board.stop(), { once: true })
})
