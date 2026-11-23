import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const WIDTH = 64
const HEIGHT = 32
const COLORS = ["#1d2038", "#38415d", "#697a91", "#b4c3ce", "#f6eedb", "#ffffff", "#c85b50", "#f27c63", "#f6bb6a", "#ffe7a0", "#447a70", "#78b38b", "#36699b", "#66a4cc", "#9b78aa", "#d69bbd"]
const COLOR_NAMES = ["Midnight", "Slate", "Fog", "Silver", "Cream", "White", "Bridge red", "Coral", "Apricot", "Sunshine", "Evergreen", "Sage", "Ocean", "Sky", "Lavender", "Rose"]
const NAMES = ["Sunny", "Clover", "Poppy", "Robin", "Fern", "Sage", "Maple", "Indigo"]
const pick = (values) => values[Math.floor(Math.random() * values.length)]
const $ = (id) => document.getElementById(id)
let savedName
try { savedName = localStorage.getItem("pixel-bay-name") } catch { /* Storage can be disabled. */ }
const user = { name: savedName?.trim().slice(0, 24) || pick(NAMES), color: pick([COLORS[6], COLORS[10], COLORS[12], COLORS[14]]) }
const ydoc = new Y.Doc()
const scene = ydoc.getMap("scene")
const pixels = ydoc.getMap("pixels")
const artistPixels = ydoc.getMap("artist_pixels")
const mural = ydoc.getMap("mural")
const localOrigin = Symbol("human-stroke")
const undoManager = new Y.UndoManager(pixels, { trackedOrigins: new Set([localOrigin]), captureTimeout: 60_000 })
const provider = new ActionCableProvider(ydoc, createConsumer(), "DocumentChannel", { id: $("pixel-studio").dataset.documentId })
const awareness = provider.awareness
awareness.setLocalStateField("user", user)

const canvas = $("mural-canvas")
const context = canvas.getContext("2d", { alpha: false })
let selectedColor = 7
let tool = "brush"
let showGrid = false
let activePointer = null
let previousCell = null
let currentCell = [32, 16]
let localCursorVisible = false
let renderQueued = false
let connection = "connecting"
let inviteController = null
let invitePending = false
let inviteError = ""
let inviteTimer
let briefTimer
let briefDirty = false
let toastTimer

const validColor = (value) => Number.isInteger(value) && value >= 0 && value < COLORS.length ? value : 0
const cellKey = (x, y) => `${x},${y}`
const effectiveColor = (key) => validColor(pixels.has(key) ? pixels.get(key) : artistPixels.has(key) ? artistPixels.get(key) : scene.get(key))
const artist = () => [...awareness.getStates().values()].find((state) => state?.artist && state.user)

function scheduleRender() {
  if (renderQueued) return
  renderQueued = true
  requestAnimationFrame(() => { renderQueued = false; renderCanvas() })
}

function renderCanvas() {
  const size = canvas.getBoundingClientRect()
  const dpr = window.devicePixelRatio || 1
  const width = Math.max(WIDTH, Math.round(size.width * dpr))
  const height = Math.max(HEIGHT, Math.round(size.height * dpr))
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height }
  context.imageSmoothingEnabled = false
  for (let y = 0; y < HEIGHT; y++) for (let x = 0; x < WIDTH; x++) {
    const left = Math.round(x * width / WIDTH)
    const top = Math.round(y * height / HEIGHT)
    context.fillStyle = COLORS[effectiveColor(cellKey(x, y))]
    context.fillRect(left, top, Math.round((x + 1) * width / WIDTH) - left, Math.round((y + 1) * height / HEIGHT) - top)
  }
  if (showGrid) {
    context.fillStyle = "#f6eedb30"
    for (let x = 1; x < WIDTH; x++) context.fillRect(Math.round(x * width / WIDTH), 0, 1, height)
    for (let y = 1; y < HEIGHT; y++) context.fillRect(0, Math.round(y * height / HEIGHT), width, 1)
  }
}

function updateUndo() { $("undo-stroke").disabled = undoManager.undoStack.length === 0 }
undoManager.on("stack-item-added", updateUndo)
undoManager.on("stack-item-popped", updateUndo)
undoManager.on("stack-cleared", updateUndo)

// Only this browser's strokes are tracked. Every pointer gesture is one undo item.
function paintCells(cells, color = selectedColor, restore = tool === "eraser") {
  ydoc.transact(() => {
    for (const [x, y] of cells) {
      if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) continue
      const key = cellKey(x, y)
      // Erasing writes a human override, so a later artist patch cannot cover it.
      pixels.set(key, restore ? validColor(scene.get(key)) : validColor(color))
    }
  }, localOrigin)
}

function paint(x, y, color = selectedColor) {
  undoManager.stopCapturing()
  paintCells([[x, y]], color, false)
  undoManager.stopCapturing()
}
window.__yrb = { provider, ydoc, scene, pixels, artistPixels, mural, user, paint, undoManager }

function lineBetween(from, to) {
  const cells = []
  let [x, y] = from
  const [endX, endY] = to
  const dx = Math.abs(endX - x), dy = Math.abs(endY - y)
  const sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1
  let error = dx - dy
  while (true) {
    cells.push([x, y])
    if (x === endX && y === endY) break
    const twice = 2 * error
    if (twice > -dy) { error -= dy; x += sx }
    if (twice < dx) { error += dx; y += sy }
  }
  return cells
}

function cellFromPointer(event) {
  const rect = canvas.getBoundingClientRect()
  if (event.clientX < rect.left || event.clientX >= rect.right || event.clientY < rect.top || event.clientY >= rect.bottom) return null
  return [Math.floor((event.clientX - rect.left) / rect.width * WIDTH), Math.floor((event.clientY - rect.top) / rect.height * HEIGHT)]
}

function pointAt(cell) {
  currentCell = cell
  localCursorVisible = true
  const key = cellKey(...cell)
  if (awareness.getLocalState()?.cell !== key) awareness.setLocalStateField("cell", key)
  $("cell-status").textContent = `${String(cell[0] + 1).padStart(2, "0")}, ${String(cell[1] + 1).padStart(2, "0")} · ${tool === "eraser" ? "Restore scene" : COLOR_NAMES[selectedColor]}`
  renderCursors()
}

canvas.addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || !event.isPrimary || activePointer !== null) return
  const cell = cellFromPointer(event)
  if (!cell) return
  event.preventDefault()
  canvas.focus({ preventScroll: true })
  canvas.setPointerCapture(event.pointerId)
  activePointer = event.pointerId
  previousCell = cell
  undoManager.stopCapturing()
  pointAt(cell)
  paintCells([cell])
})
canvas.addEventListener("pointermove", (event) => {
  if (!event.isPrimary || (activePointer !== null && activePointer !== event.pointerId)) return
  const cell = cellFromPointer(event)
  if (!cell) { previousCell = null; return }
  pointAt(cell)
  if (activePointer === event.pointerId) {
    if (!previousCell || cell[0] !== previousCell[0] || cell[1] !== previousCell[1]) paintCells(previousCell ? lineBetween(previousCell, cell) : [cell])
    previousCell = cell
  }
})
function endStroke(event) {
  if (event.pointerId !== activePointer) return
  if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId)
  activePointer = null
  previousCell = null
  undoManager.stopCapturing()
  if (event.pointerType === "touch") hideCursor()
}
canvas.addEventListener("pointerup", endStroke)
canvas.addEventListener("pointercancel", endStroke)
canvas.addEventListener("lostpointercapture", endStroke)
function hideCursor() {
  localCursorVisible = false
  awareness.setLocalStateField("cell", null)
  renderCursors()
}
canvas.addEventListener("pointerleave", () => { if (activePointer === null) hideCursor() })
canvas.addEventListener("blur", () => { if (activePointer === null) hideCursor() })
canvas.addEventListener("focus", () => pointAt(currentCell))

function chooseTool(nextTool) {
  tool = nextTool
  $("brush-tool").setAttribute("aria-pressed", String(tool === "brush"))
  $("eraser-tool").setAttribute("aria-pressed", String(tool === "eraser"))
  if (localCursorVisible) pointAt(currentCell)
}
function undoStroke() { undoManager.stopCapturing(); undoManager.undo(); updateUndo() }
$("brush-tool").addEventListener("click", () => chooseTool("brush"))
$("eraser-tool").addEventListener("click", () => chooseTool("eraser"))
$("undo-stroke").addEventListener("click", undoStroke)
$("grid-tool").addEventListener("click", () => {
  showGrid = !showGrid
  $("grid-tool").setAttribute("aria-pressed", String(showGrid))
  $("grid-tool").setAttribute("aria-label", showGrid ? "Hide pixel grid" : "Show pixel grid")
  scheduleRender()
})

const swatches = COLORS.map((color, index) => {
  const button = document.createElement("button")
  button.type = "button"
  button.className = "swatch"
  button.style.background = color
  button.style.setProperty("--indicator", [3, 4, 5, 8, 9, 11, 13, 15].includes(index) ? COLORS[0] : COLORS[5])
  button.setAttribute("aria-label", `${COLOR_NAMES[index]} (${color})`)
  button.setAttribute("aria-pressed", String(index === selectedColor))
  button.title = COLOR_NAMES[index]
  button.addEventListener("click", () => {
    selectedColor = index
    swatches.forEach((swatch, i) => swatch.setAttribute("aria-pressed", String(i === index)))
    chooseTool("brush")
  })
  return button
})
$("palette").replaceChildren(...swatches)

document.addEventListener("keydown", (event) => {
  if (event.target.closest("input,textarea,[contenteditable=true]") || event.altKey) return
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
    event.preventDefault()
    if (event.shiftKey) { undoManager.redo(); updateUndo() } else undoStroke()
    return
  }
  if (event.ctrlKey || event.metaKey) return
  if (event.key.toLowerCase() === "b") chooseTool("brush")
  if (event.key.toLowerCase() === "e") chooseTool("eraser")
  if (event.target !== canvas) return
  const moves = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }
  if (moves[event.key]) {
    event.preventDefault()
    const [dx, dy] = moves[event.key]
    pointAt([Math.max(0, Math.min(WIDTH - 1, currentCell[0] + dx)), Math.max(0, Math.min(HEIGHT - 1, currentCell[1] + dy))])
  } else if (event.key === " " || event.key === "Enter") {
    event.preventDefault()
    undoManager.stopCapturing()
    paintCells([currentCell])
    undoManager.stopCapturing()
  }
})

function safePeerColor(value) { return /^#[0-9a-f]{6}$/i.test(value || "") ? value : COLORS[6] }
function renderCursors() {
  const cursors = []
  for (const [id, state] of awareness.getStates()) {
    if (!state?.user || typeof state.cell !== "string" || !/^\d+,\d+$/.test(state.cell)) continue
    const local = id === awareness.clientID
    if (local && !localCursorVisible) continue
    const [x, y] = state.cell.split(",").map(Number)
    if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) continue
    const cursor = document.createElement("span")
    cursor.className = `pixel-cursor${local ? " local" : ""}${y < 3 ? " near-top" : ""}${x > 48 ? " near-right" : ""}`
    cursor.style.left = `${x / WIDTH * 100}%`
    cursor.style.top = `${y / HEIGHT * 100}%`
    cursor.style.setProperty("--cursor", safePeerColor(state.user.color))
    cursor.dataset.name = String(state.user.name || "Visitor").slice(0, 24)
    cursors.push(cursor)
  }
  $("cursor-layer").replaceChildren(...cursors)
}

function renderPresence() {
  const people = [...awareness.getStates().entries()].filter(([, state]) => state?.user)
  people.sort(([a], [b]) => a === awareness.clientID ? -1 : b === awareness.clientID ? 1 : a - b)
  $("presence-count").textContent = people.length === 1 ? "Just you" : `${people.length} together`
  $("presence-list").replaceChildren(...people.map(([id, state]) => {
    const person = document.createElement("div")
    person.className = "presence-person"
    const dot = document.createElement("span")
    dot.className = "person-dot"
    dot.style.setProperty("--person", safePeerColor(state.user.color))
    const name = document.createElement("span")
    name.className = "person-name"
    name.textContent = String(state.user.name || "Visitor").slice(0, 24)
    const detail = document.createElement("span")
    detail.className = "person-description"
    detail.textContent = id === awareness.clientID ? "you" : state.artist ? "AI artist" : "painting pal"
    person.append(dot, name, detail)
    return person
  }))
  renderCursors()
  renderArtist()
}

$("your-name").value = user.name
$("your-name").addEventListener("change", (event) => {
  user.name = event.target.value.trim().slice(0, 24) || user.name
  event.target.value = user.name
  try { localStorage.setItem("pixel-bay-name", user.name) } catch { /* The name still works for this session. */ }
  awareness.setLocalStateField("user", { ...user })
})

function flushBrief() {
  clearTimeout(briefTimer)
  if (!briefDirty) return
  mural.set("brief", $("artist-brief").value.slice(0, 240))
  briefDirty = false
}
$("artist-brief").addEventListener("input", () => {
  briefDirty = true
  clearTimeout(briefTimer)
  briefTimer = setTimeout(flushBrief, 350)
})
$("artist-brief").addEventListener("blur", flushBrief)

function renderArtist() {
  const present = artist()
  const phase = mural.get("phase")
  const stopped = mural.get("enabled") === false
  if (present) { invitePending = false; inviteError = ""; clearTimeout(inviteTimer) }
  $("artist-badge").textContent = present ? "IN STUDIO" : invitePending ? "INVITED" : "OFFLINE"
  $("artist-badge").classList.toggle("online", !!present)
  $("invite-artist").hidden = !!present
  $("invite-artist-button").disabled = invitePending || connection !== "synced"
  $("invite-artist-button").textContent = invitePending ? "Inviting Ruby…" : "✦ Invite Ruby to paint"
  $("remove-artist").hidden = !present && !invitePending
  $("remove-artist").textContent = present ? (stopped ? "Ruby is taking a break…" : "Let Ruby take a break") : "Cancel invitation"
  $("remove-artist").disabled = !!present && stopped
  const error = inviteError || (phase === "error" ? String(mural.get("note") || mural.get("status") || "Ruby couldn't finish that turn. Try inviting Ruby again.") : "")
  $("artist-note").classList.toggle("error", !!error)
  $("artist-phase-dot").className = `live-dot${error || !present ? " offline" : phase === "thinking" ? " connecting" : ""}`
  $("artist-phase").textContent = error ? "Could not finish this turn" : present ? (stopped ? "Wrapping up" : phase === "thinking" ? "Planning the next detail" : phase === "painting" ? "Painting" : "Studying the canvas") : invitePending ? "Waiting for Ruby to arrive" : "Ready when you are"
  $("artist-commentary").textContent = error || (present ? String(mural.get("note") || "Reading the canvas before adding new details.") : invitePending ? "Ruby will appear here as soon as the artist joins." : "Invite Ruby to add details to the canvas.")
  const turns = Number(mural.get("turns")) || 0
  const mode = mural.get("mode")
  $("artist-meta").hidden = !present && !turns
  $("artist-meta").textContent = `${turns} ${turns === 1 ? "creative turn" : "creative turns"}${mode === "test" ? " · TEST MODE" : ""}`
  if (!briefDirty && document.activeElement !== $("artist-brief")) $("artist-brief").value = String(mural.get("brief") || "").slice(0, 240)
}

function invitationFailed(message) { invitePending = false; inviteError = message; clearTimeout(inviteTimer); renderArtist() }
$("invite-artist").addEventListener("submit", async (event) => {
  event.preventDefault()
  if (invitePending || artist() || connection !== "synced") return
  flushBrief()
  inviteError = ""
  invitePending = true
  const controller = new AbortController()
  inviteController?.abort()
  inviteController = controller
  renderArtist()
  // Presence, rather than the HTTP response, is the source of truth for membership.
  inviteTimer = setTimeout(() => {
    if (!artist() && inviteController === controller) invitationFailed("Ruby hasn't arrived yet. You can try inviting again.")
  }, 15_000)
  try {
    const response = await fetch(event.currentTarget.action, {
      method: "POST",
      headers: {
        Accept: "text/event-stream",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        "X-Pixel-Stop-Version": String(mural.get("stop_version") || ""),
      },
      credentials: "same-origin",
      signal: controller.signal,
    })
    if (!response.ok) {
      const message = response.status === 409 ? "Ruby is already joining this room. Give it a moment, then try again if needed." : response.status === 503 ? "Configure a model API key on the server to invite Ruby." : `Ruby couldn't join (${response.status}). Please try again.`
      response.body?.cancel().catch(() => {})
      throw new Error(message)
    }
    // Falcon holds the artist's lifetime in this stream. Puma responds with 204.
    const reader = response.body?.getReader()
    if (reader) {
      try { while (!(await reader.read()).done) { /* Keep the artist's connection open. */ } }
      finally { reader.releaseLock() }
      if (inviteController === controller && invitePending && !artist()) invitationFailed("Ruby left before joining the studio. Try inviting again.")
    }
  } catch (error) {
    if (inviteController === controller && error.name !== "AbortError") invitationFailed(error.message || "Ruby couldn't connect. Please try again.")
  } finally {
    if (inviteController === controller && !invitePending) { inviteController = null; renderArtist() }
  }
})

$("remove-artist").addEventListener("click", () => {
  const stopVersion = [...crypto.getRandomValues(new Uint8Array(16))].map((byte) => byte.toString(16).padStart(2, "0")).join("")
  ydoc.transact(() => {
    mural.set("stop_version", stopVersion)
    mural.set("enabled", false)
  })
  inviteController?.abort()
  inviteController = null
  clearTimeout(inviteTimer)
  invitePending = false
  inviteError = ""
  renderArtist()
})

function toast(message) {
  $("studio-toast").textContent = message
  $("studio-toast").hidden = false
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { $("studio-toast").hidden = true }, 4000)
}
$("share-mural").addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(window.location.href); toast("Room link copied. Bring a friend to the bay.") }
  catch { window.prompt("Copy this link to invite a friend:", window.location.href) }
})

for (const map of [scene, pixels, artistPixels]) map.observe(scheduleRender)
mural.observe(renderArtist)
awareness.on("update", renderPresence)
provider.onStatusChange(({ status }) => {
  connection = status
  const connected = status === "synced"
  $("connection-status").textContent = connected ? "Live · a shared canvas" : status === "disconnected" ? "Reconnecting · keep drawing" : "Connecting to the studio…"
  $("connection-dot").className = `live-dot${connected ? "" : status === "disconnected" ? " offline" : " connecting"}`
  renderArtist()
})
new ResizeObserver(scheduleRender).observe($("canvas-wrap"))
window.addEventListener("resize", scheduleRender)
window.addEventListener("pagehide", () => { flushBrief(); inviteController?.abort() })
renderPresence()
scheduleRender()
provider.connect()
