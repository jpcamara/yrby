// Opaque-state demo: a town everyone builds, with a Ruby planner in it.
// Shared state is four Y.Maps keyed by cell ("x,y"): the tiles, the signs'
// text, who wrote each tile, and the cells the planner has claimed. A paint
// is one map.set, so paints to different cells merge and the same cell is
// last-writer-wins. Where everyone stands travels in awareness, not the
// document. The planner (CityPlanner) joins as a peer over the same
// websocket and writes the same maps; this page only draws what is there.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import TILESET from "./city_tiles.json"

const W = 48, H = 48, T = TILESET.size
const F = TILESET.frames
const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const SPRITES = ["person_red", "person_blue", "person_green", "person_yellow"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }
const sprite = pick(SPRITES)

// The palette: what a tap paints. "walk" moves your character instead.
const TOOLS = [
  ["walk", "Walk", sprite], ["erase", "Grass", "grass"], ["road", "Road", "road"], ["water", "Water", "water"],
  ["bridge", "Bridge", "bridge_h"], ["house_red", "House", "house_red"], ["house_blue", "House", "house_blue"],
  ["house_orange", "House", "house_orange"], ["shop", "Shop", "shop"], ["park", "Park", "park"], ["sign", "Sign", "sign"],
]
const ROADS = new Set(["road", "bridge"])

const stage = document.getElementById("stage")
const map = document.getElementById("map")
const overlay = document.getElementById("overlay")
const tags = document.getElementById("tags")
const paletteEl = document.getElementById("palette")
const statusEl = document.getElementById("status")
const presenceEl = document.getElementById("presence")
const offlineEl = document.getElementById("offline")
const attributionEl = document.getElementById("attribution")
const legendEl = document.getElementById("legend")
const inviteEl = document.querySelector(".invite-planner")
const documentId = stage.dataset.documentId
const ctx = map.getContext("2d")
const octx = overlay.getContext("2d")

const ydoc = new Y.Doc()
const tiles = ydoc.getMap("tiles")
const signs = ydoc.getMap("signs")
const authors = ydoc.getMap("authors")
const claims = ydoc.getMap("claims")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
const awareness = provider.awareness

const key = (x, y) => `${x},${y}`
const parse = (k) => { const [x, y] = k.split(",").map(Number); return x >= 0 && y >= 0 && x < W && y < H ? [x, y] : null }
const inBounds = (x, y) => x >= 0 && y >= 0 && x < W && y < H

// --- the sheet ---------------------------------------------------------------
// One image, one 16x16 frame per name; drawing a cell is one drawImage.
const sheet = new Image()
sheet.src = "/city/tiles.png"
function frame(target, name, x, y) {
  target.drawImage(sheet, F[name] * T, 0, T, T, x * T, y * T, T, T)
}

// --- me ----------------------------------------------------------------------
let tool = "house_red"
let pos = { x: 8 + Math.floor(Math.random() * 32), y: 8 + Math.floor(Math.random() * 32) }
const presence = () => ({ user, sprite, pos, tool })
awareness.setLocalState(presence())

function setTool(name) {
  tool = name
  for (const b of paletteEl.children) b.setAttribute("aria-pressed", String(b.dataset.tool === name))
  awareness.setLocalStateField("tool", tool)
}
function moveTo(x, y) {
  if (!inBounds(x, y)) return
  pos = { x, y }
  awareness.setLocalStateField("pos", pos)
  renderOverlay()
}

for (const [name, label, icon] of TOOLS) {
  const b = document.createElement("button")
  b.type = "button"
  b.dataset.tool = name
  const c = document.createElement("canvas")
  c.width = c.height = T
  b.appendChild(c)
  b.appendChild(document.createTextNode(label))
  b.addEventListener("click", () => setTool(name))
  sheet.addEventListener("load", () => {
    const cc = c.getContext("2d")
    if (name !== "walk" && name !== "erase" && name !== "water" && name !== "bridge" && name !== "road") frame(cc, "grass", 0, 0)
    if (name === "walk") frame(cc, "grass", 0, 0)
    frame(cc, icon, 0, 0)
  })
  paletteEl.appendChild(b)
}

// --- drawing -----------------------------------------------------------------
// The map canvas is W*T by H*T backing pixels; CSS scales it up with
// image-rendering: pixelated. A road shows a grass edge on each side with no
// road beside it, and a bridge turns to follow the road it carries.
const grassFrame = (x, y) => ((x * 31 + y * 17) % 23 === 0 ? "grass_flowers" : (x * 13 + y * 7) % 29 === 0 ? "grass_sparkle" : "grass")
function drawCell(x, y, at = (k) => tiles.get(k)) {
  const tile = at(key(x, y))
  const road = (dx, dy) => inBounds(x + dx, y + dy) && ROADS.has(at(key(x + dx, y + dy)))
  if (tile === "road") {
    frame(ctx, "road", x, y)
    if (!road(0, -1)) frame(ctx, "road_edge_up", x, y)
    if (!road(1, 0)) frame(ctx, "road_edge_right", x, y)
    if (!road(0, 1)) frame(ctx, "road_edge_down", x, y)
    if (!road(-1, 0)) frame(ctx, "road_edge_left", x, y)
  } else if (tile === "bridge") {
    frame(ctx, road(-1, 0) || road(1, 0) ? "bridge_h" : road(0, -1) || road(0, 1) ? "bridge_v" : "bridge_h", x, y)
  } else if (tile && F[tile] !== undefined) {
    frame(ctx, tile, x, y)
  } else {
    frame(ctx, grassFrame(x, y), x, y)
  }
}
function drawAll(at) {
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) drawCell(x, y, at)
}
// A changed cell redraws itself and its four neighbours, whose edges depend on it.
function drawAround(k) {
  const cell = parse(k)
  if (!cell) return
  const [x, y] = cell
  for (const [dx, dy] of [[0, 0], [0, -1], [1, 0], [0, 1], [-1, 0]]) if (inBounds(x + dx, y + dy)) drawCell(x + dx, y + dy)
}

// The overlay: the planner's claims, the attribution tint, and everyone's
// character. Redrawn whole; it is small.
let attribution = false
function renderOverlay() {
  octx.clearRect(0, 0, W * T, H * T)
  if (attribution) {
    for (const [k, who] of authors.entries()) {
      const cell = parse(k)
      if (!cell || !tiles.has(k)) continue
      octx.fillStyle = who.startsWith("a:") ? "rgba(227,134,40,.55)" : "rgba(37,99,235,.45)"
      octx.fillRect(cell[0] * T, cell[1] * T, T, T)
    }
  }
  for (const k of claims.keys()) { const cell = parse(k); if (cell) frame(octx, "marker", cell[0], cell[1]) }
  for (const s of people()) frame(octx, s.planner ? "planner" : SPRITES.includes(s.sprite) ? s.sprite : SPRITES[0], s.pos.x, s.pos.y)
  renderTags()
}
function people() {
  const out = []
  for (const [id, s] of awareness.getStates()) {
    if (s?.user && s.pos && inBounds(s.pos.x, s.pos.y)) out.push({ ...s, me: id === awareness.clientID })
  }
  return out
}
// Name tags and sign text are DOM, placed in percentages of the stage, so
// they stay readable at any scale.
function renderTags() {
  const els = []
  for (const s of people()) {
    const el = document.createElement("div")
    el.className = "tag" + (s.me ? " me" : "")
    el.style.background = s.user.color
    el.style.left = `${((s.pos.x + 0.5) / W) * 100}%`
    el.style.top = `${(s.pos.y / H) * 100}%`
    el.textContent = s.user.name + (s.status ? ` · ${s.status}` : "")
    els.push(el)
  }
  for (const [k, text] of signs.entries()) {
    const cell = parse(k)
    if (!cell || tiles.get(k) !== "sign" || !text) continue
    const el = document.createElement("div")
    el.className = "sign-text"
    el.style.left = `${((cell[0] + 0.5) / W) * 100}%`
    el.style.top = `${(cell[1] / H) * 100}%`
    el.textContent = String(text).slice(0, 14)
    els.push(el)
  }
  tags.replaceChildren(...els)
}

// The stage fills what room there is: on a screen with space to spare, in
// half steps of the backing size, so a backing pixel is a whole number of
// device pixels on a 2x display; on a phone, whatever fits.
function fit() {
  const room = Math.min(stage.parentElement.clientWidth, window.innerHeight - 120)
  const ratio = room / (W * T)
  const scale = ratio >= 1 ? Math.floor(ratio * 2) / 2 : ratio
  stage.style.width = stage.style.height = `${Math.floor(W * T * scale)}px`
}
window.addEventListener("resize", fit)
fit()

// --- painting ----------------------------------------------------------------
// Pointer events are coalesced into one transaction every 40 ms, so a drag is
// one update per tick rather than one per cell. The tile and its author go in
// the same transaction; erasing takes both out, and a sign's text with them.
const pending = new Map()
let flush = null
function paint(x, y, name = tool) {
  if (!inBounds(x, y) || name === "walk" || name === "sign") return
  pending.set(key(x, y), name)
  flush ??= setTimeout(() => {
    flush = null
    ydoc.transact(() => {
      for (const [k, name] of pending) {
        if (name === "erase") { if (tiles.has(k)) { tiles.delete(k); authors.delete(k); signs.delete(k) } }
        else if (tiles.get(k) !== name) { tiles.set(k, name); authors.set(k, `h:${user.name}`); signs.delete(k) }
      }
    })
    pending.clear()
  }, 40)
}
function placeSign(x, y, text) {
  if (!inBounds(x, y)) return
  const k = key(x, y)
  text ??= prompt("What should the sign say? The planner reads PARK, SHOP, ROAD, BRIDGE, NO BUILD, and CLEAR.", signs.get(k) || "")
  if (text === null) return
  ydoc.transact(() => {
    tiles.set(k, "sign")
    authors.set(k, `h:${user.name}`)
    signs.set(k, text.trim())
  })
}

const cellAt = (event) => {
  const r = stage.getBoundingClientRect()
  return [Math.floor(((event.clientX - r.left) / r.width) * W), Math.floor(((event.clientY - r.top) / r.height) * H)]
}
let painting = false
overlay.addEventListener("pointerdown", (e) => {
  e.preventDefault()
  const [x, y] = cellAt(e)
  if (tool === "walk") {
    if (tiles.get(key(x, y)) === "sign") placeSign(x, y)
    else moveTo(x, y)
    return
  }
  if (tool === "sign") return placeSign(x, y)
  painting = true
  overlay.setPointerCapture(e.pointerId)
  paint(x, y)
})
overlay.addEventListener("pointermove", (e) => { if (painting) paint(...cellAt(e)) })
const stop = () => { painting = false }
overlay.addEventListener("pointerup", stop)
overlay.addEventListener("pointercancel", stop)

const MOVES = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] }
window.addEventListener("keydown", (e) => {
  if (!MOVES[e.key] || e.target.matches("input, textarea")) return
  e.preventDefault()
  moveTo(pos.x + MOVES[e.key][0], pos.y + MOVES[e.key][1])
})

// --- offline -----------------------------------------------------------------
// Going offline drops the cable subscription and nothing else. Edits keep
// landing in the local doc and in the provider's outbox, which replays them
// when the subscription comes back; the reconnect handshake brings in what
// everyone else did meanwhile. Presence is cleared on the way out (peers see
// us leave) and set again before reconnecting, so it goes out with the
// handshake.
let offline = false
let waiting = 0
ydoc.on("update", (_update, origin) => { if (offline && origin !== provider.session) { waiting++; renderStatus() } })
function goOffline() {
  if (offline) return
  offline = true
  waiting = 0
  provider.disconnect()
  offlineEl.textContent = "Reconnect"
  renderStatus()
}
function reconnect() {
  if (!offline) return
  offline = false
  awareness.setLocalState(presence())
  provider.connect()
  offlineEl.textContent = "Go offline"
  renderStatus()
}
offlineEl.addEventListener("click", () => (offline ? reconnect() : goOffline()))

function toggleAttribution(on = !attribution) {
  attribution = on
  attributionEl.setAttribute("aria-pressed", String(on))
  attributionEl.textContent = on ? "Hide who built what" : "Show who built what"
  legendEl.hidden = !on
  renderOverlay()
}
attributionEl.addEventListener("click", () => toggleAttribution())

// --- the roster and the status ----------------------------------------------
const planner = () => [...awareness.getStates().values()].find((s) => s?.planner)
function renderPresence() {
  presenceEl.replaceChildren(...[...awareness.getStates().values()].filter((s) => s?.user).map((s) => {
    const chip = document.createElement("span")
    chip.className = "chip"
    chip.style.background = s.user.color
    chip.textContent = s.user.name + (s.user.name === user.name && !s.planner ? " (you)" : "") + (s.status ? ` · ${s.status}` : "")
    return chip
  }))
  if (inviteEl) { inviteEl.disabled = !!planner(); inviteEl.textContent = planner() ? "The planner is here" : "Invite the planner" }
}
function renderStatus() {
  statusEl.classList.toggle("offline", offline)
  if (offline) { statusEl.textContent = `offline as ${user.name} · ${waiting} change${waiting === 1 ? "" : "s"} waiting to sync`; return }
  const status = provider.status
  statusEl.textContent = status === "synced" ? `synced as ${user.name} · ${tiles.size} tiles` : `${status} as ${user.name}…`
}

// The invite is a fetch, not a navigation. Under Falcon the answer is a
// stream that stays open while the planner runs, and this page holds it:
// leaving the page closes it, and the planner goes with it. Under Puma the
// answer is an empty 204 and the planner runs on its own.
inviteEl?.closest("form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  const response = await fetch(e.target.action, { method: "POST", headers: { Accept: "text/event-stream" } })
  const reader = response.body?.getReader()
  while (reader && !(await reader.read()).done) { /* hold the stream until the planner leaves */ }
})

// --- timelapse ---------------------------------------------------------------
// The audit endpoint lists every update the server recorded for this
// document, in order. They are applied one by one to a scratch Y.Doc, with a
// frame kept along the way, and the scrubber picks which frame the map
// canvas shows. Closing the panel returns to the live map.
const timelapse = document.getElementById("timelapse")
const scrub = document.getElementById("timelapse-scrub")
const play = document.getElementById("timelapse-play")
const caption = document.getElementById("timelapse-caption")
const MAX_FRAMES = 240
let replaying = false
let frames = []
let timer = null
const fromBase64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
async function loadTimelapse() {
  stopTimelapse()
  caption.textContent = "loading…"
  const response = await fetch(timelapse.dataset.url, { headers: { Accept: "application/json" } })
  const { count, updates } = await response.json()
  const scratch = new Y.Doc()
  const scratchTiles = scratch.getMap("tiles")
  const every = Math.max(1, Math.ceil(count / MAX_FRAMES))
  frames = [{ after: 0, tiles: new Map() }]
  updates.forEach((u, i) => {
    Y.applyUpdate(scratch, fromBase64(u))
    if ((i + 1) % every === 0 || i === updates.length - 1) frames.push({ after: i + 1, tiles: new Map(scratchTiles.entries()) })
  })
  scrub.max = frames.length - 1
  showFrame(frames.length - 1)
}
function showFrame(i) {
  const f = frames[i]
  if (!f) return
  replaying = true
  scrub.value = i
  drawAll((k) => f.tiles.get(k))
  caption.textContent = `after ${f.after} of ${frames.at(-1).after} updates`
}
function stopTimelapse() { clearInterval(timer); timer = null; play.textContent = "Play" }
scrub.addEventListener("input", () => { stopTimelapse(); showFrame(Number(scrub.value)) })
play.addEventListener("click", () => {
  if (timer) return stopTimelapse()
  let i = Number(scrub.value) >= frames.length - 1 ? 0 : Number(scrub.value)
  play.textContent = "Stop"
  timer = setInterval(() => { showFrame(i); if (++i >= frames.length) stopTimelapse() }, 60)
})
document.getElementById("timelapse-refresh").addEventListener("click", loadTimelapse)
timelapse.addEventListener("toggle", () => {
  if (timelapse.open) loadTimelapse()
  else { stopTimelapse(); replaying = false; drawAll() }
})

// --- wiring ------------------------------------------------------------------
// Everything on screen comes from the document and the presence.
tiles.observe((event) => { if (!replaying) for (const k of event.keysChanged) drawAround(k); renderOverlay(); renderStatus() })
signs.observe(renderTags)
authors.observe(() => { if (attribution) renderOverlay() })
claims.observe(renderOverlay)
awareness.on("change", () => { renderOverlay(); renderPresence() })
sheet.addEventListener("load", () => { drawAll(); renderOverlay() })

provider.onStatusChange(() => { renderStatus(); if (provider.status === "synced") { drawAll(); renderOverlay() } })
setTool(tool)
renderPresence()
renderStatus()
window.__yrb = { provider, ydoc, tiles, signs, authors, claims, user, paint, placeSign, moveTo, setTool, goOffline, reconnect, toggleAttribution, get pos() { return pos } }
provider.connect()
