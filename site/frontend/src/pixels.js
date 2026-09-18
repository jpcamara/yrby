// A shared pixel canvas, r/place style. The shared state is one Y.Map with one
// key per cell ("x,y") holding a palette index. Painting a cell is a single
// map.set: paints to different cells merge, and two paints to the same cell
// keep the last write, which is the r/place rule. The server records each
// update as a row and never looks inside it. PixelChannel is DocumentChannel
// with compaction off, so those rows are the whole history the timelapse
// panel replays in Ruby.
import * as Y from "yjs"
import { connectRoom, user, wireStoredPanel } from "./room.js"

const mount = document.getElementById("pixels")
const canvas = document.getElementById("pixel-canvas")
const cursors = document.getElementById("pixel-cursors")
const swatches = [...document.querySelectorAll("#palette .swatch")]
const SIZE = canvas.width
// The palette is the one the server rendered into the swatches
// (PixelCanvas::PALETTE), so the page and the PNG agree on every color.
const PALETTE = swatches.map((b) => b.dataset.color)
const ctx = canvas.getContext("2d")

const ydoc = new Y.Doc()
const pixels = ydoc.getMap("pixels")
const provider = connectRoom(ydoc, mount, { channel: "PixelChannel" })

// --- the palette -------------------------------------------------------------
// Starts on a random color (never the unpainted white), so two windows opened
// side by side usually differ. The choice rides along in awareness so peers
// see it on your cursor.
let color = 1 + Math.floor(Math.random() * (PALETTE.length - 1))
function pickColor(index) {
  color = index
  for (const b of swatches) b.setAttribute("aria-pressed", String(Number(b.dataset.index) === index))
  provider.awareness.setLocalStateField("color", index)
}
for (const b of swatches) b.addEventListener("click", () => pickColor(Number(b.dataset.index)))
pickColor(color)

// --- drawing -----------------------------------------------------------------
// The canvas is SIZE x SIZE backing pixels; CSS scales it up with
// image-rendering: pixelated, so one fillRect per changed key is all the
// drawing there is.
function drawCell(key) {
  const [x, y] = key.split(",").map(Number)
  ctx.fillStyle = PALETTE[pixels.get(key)] ?? PALETTE[0]
  ctx.fillRect(x, y, 1, 1)
}
function drawAll() {
  ctx.fillStyle = PALETTE[0]
  ctx.fillRect(0, 0, SIZE, SIZE)
  for (const key of pixels.keys()) drawCell(key)
}
pixels.observe((event) => { for (const key of event.keysChanged) drawCell(key) })
drawAll()

// --- painting ----------------------------------------------------------------
// Pointer events are coalesced into one transaction every 40 ms, so a drag
// stroke is one update per tick rather than one per cell. A cell that already
// holds the color is skipped, so nothing goes out for it.
const pending = new Map()
let flush = null
function paint(x, y, index = color) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) return
  pending.set(`${x},${y}`, index)
  flush ??= setTimeout(() => {
    flush = null
    ydoc.transact(() => {
      for (const [key, value] of pending) if (pixels.get(key) !== value) pixels.set(key, value)
    })
    pending.clear()
  }, 40)
}

const cellAt = (event) => {
  const r = canvas.getBoundingClientRect()
  return [
    Math.floor(((event.clientX - r.left) / r.width) * SIZE),
    Math.floor(((event.clientY - r.top) / r.height) * SIZE),
  ]
}
let painting = false
canvas.addEventListener("pointerdown", (e) => {
  e.preventDefault()
  painting = true
  canvas.setPointerCapture(e.pointerId)
  paint(...cellAt(e))
})
canvas.addEventListener("pointermove", (e) => {
  const [x, y] = cellAt(e)
  point(x, y)
  if (painting) paint(x, y)
})
const stop = () => { painting = false }
canvas.addEventListener("pointerup", stop)
canvas.addEventListener("pointercancel", stop)
canvas.addEventListener("pointerleave", () => point(null))

// --- presence ----------------------------------------------------------------
// The cell under each person's pointer travels in awareness, like the editors'
// carets: relayed by the server, stored nowhere. Throttled to 50 ms so a fast
// sweep across the grid doesn't send a frame per pixel.
let pointed = null
let pointTimer = null
function point(x, y) {
  const next = x === null || x < 0 || y < 0 || x >= SIZE || y >= SIZE ? null : { x, y }
  const same = next === null ? pointed === null : pointed !== null && pointed.x === next.x && pointed.y === next.y
  if (same) return
  pointed = next
  pointTimer ??= setTimeout(() => {
    pointTimer = null
    provider.awareness.setLocalStateField("cell", pointed)
  }, 50)
}

// One outlined cell per peer, in the color they are holding, with their name.
// Positioned in percentages of the stage so it scales with the canvas.
function renderCursors() {
  const me = provider.awareness.clientID
  const els = []
  for (const [id, state] of provider.awareness.getStates()) {
    if (id === me || !state.cell || !state.user) continue
    const el = document.createElement("div")
    el.className = "pixel-cursor"
    el.style.left = `${(state.cell.x / SIZE) * 100}%`
    el.style.top = `${(state.cell.y / SIZE) * 100}%`
    el.style.width = el.style.height = `${100 / SIZE}%`
    el.style.borderColor = PALETTE[state.color] ?? state.user.color
    const name = document.createElement("span")
    name.className = "pixel-cursor-name"
    name.style.background = state.user.color
    name.textContent = state.user.name
    el.appendChild(name)
    els.push(el)
  }
  cursors.replaceChildren(...els)
}
provider.awareness.on("change", renderCursors)

// --- the Ruby renders --------------------------------------------------------
// The PNG panel fetches on open and refetches, debounced, after each change
// while open. A second of quiet before the refetch: painting is continuous,
// and the endpoint counts against the site's page throttle.
function wirePngPanel() {
  const details = document.getElementById("png-panel")
  const img = document.getElementById("png")
  if (!details || !img) return
  const load = () => {
    img.src = `${img.dataset.url}?t=${Date.now()}`
    img.hidden = false
  }
  let timer = null
  ydoc.on("update", () => {
    if (!details.open) return
    clearTimeout(timer)
    timer = setTimeout(load, 1000)
  })
  details.addEventListener("toggle", () => { if (details.open) load() })
}

// The timelapse fetches its frames on open (and on Refresh), then scrubs or
// plays through them. Every frame is a PNG Ruby rendered; the page only
// chooses which one to show.
function wireTimelapsePanel() {
  const details = document.getElementById("timelapse-panel")
  if (!details) return
  const img = document.getElementById("timelapse-frame")
  const scrub = document.getElementById("timelapse-scrub")
  const play = document.getElementById("timelapse-play")
  const refresh = document.getElementById("timelapse-refresh")
  const caption = document.getElementById("timelapse-caption")
  let frames = []
  let total = 0
  let timer = null

  const show = (i) => {
    const frame = frames[i]
    if (!frame) return
    img.src = frame.png
    img.hidden = false
    scrub.value = i
    caption.textContent = `after ${frame.after} of ${total} update${total === 1 ? "" : "s"}`
  }
  const stop = () => {
    clearInterval(timer)
    timer = null
    play.textContent = "Play"
  }
  const load = async () => {
    stop()
    try {
      const response = await fetch(details.dataset.url, { headers: { Accept: "application/json" } })
      const data = await response.json()
      frames = data.frames
      total = data.updates
      scrub.max = Math.max(0, frames.length - 1)
      show(frames.length - 1)
    } catch {
      caption.textContent = "(could not load)"
    }
  }
  scrub.addEventListener("input", () => { stop(); show(Number(scrub.value)) })
  play.addEventListener("click", () => {
    if (timer) return stop()
    let i = Number(scrub.value) >= frames.length - 1 ? 0 : Number(scrub.value)
    play.textContent = "Stop"
    timer = setInterval(() => { show(i); if (++i >= frames.length) stop() }, 80)
  })
  refresh.addEventListener("click", load)
  details.addEventListener("toggle", () => { if (details.open) load(); else stop() })
}

wirePngPanel()
wireTimelapsePanel()
window.__yrby = { provider, ydoc, pixels, user, paint, pickColor }
wireStoredPanel(ydoc)
provider.connect()
