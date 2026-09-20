// Opaque-state demo: a town everyone builds, with a Ruby planner and the
// townsfolk in it. Shared state is six Y.Maps keyed by cell ("x,y"): the
// tiles, the signs' text, who wrote each tile, the cells the planner has
// claimed, what the mayor read a sign as, and one entry of metadata, the
// terrain's seed. A paint is one map.set, so paints to different cells
// merge and the same cell is last-writer-wins. A building wider than a
// cell is one key at its top-left cell, "shop@2x2", and the page draws it
// over the cells it covers.
//
// Everything that moves is awareness, not the document: where everyone
// stands, what they say, their hops, and the whole life of the town that
// CityLife publishes (the pedestrians, the cars, the gulls, the boats, the
// smoking chimneys, the time of day). The document holds only what people
// and the planner build; nothing here writes a footstep into it.
//
// Drawing is in layers. The town is painted once into an offscreen canvas
// the size of the map and repainted only around cells that change; each
// frame blits the part the camera shows. Everything that moves is drawn on
// a second canvas over it, and the time of day tints a third. Frames are
// batched with requestAnimationFrame; the page's own presence goes out at
// most a dozen times a second.
import * as Y from "yjs"
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"
import { Awareness, encodeAwarenessUpdate, applyAwarenessUpdate } from "y-protocols/awareness"
import ATLAS from "./city_tiles.json"

const W = 96, H = 96, T = 16
const F = ATLAS.frames
const DAY = 360_000 // ms in a day of the town's clock, as CityLife counts it
const LIFE_TICK = 500 // ms between the townsfolk's frames; positions are eased over one tick
const NAMES = ["Ada", "Grace", "Linus", "Yukihiro", "Barbara", "Dennis", "Radia", "Alan"]
const COLORS = ["#f87171", "#fb923c", "#facc15", "#4ade80", "#22d3ee", "#818cf8", "#e879f9", "#f472b6"]
const SPRITES = ["person_red", "person_blue", "person_green", "person_yellow"]
const pick = (a) => a[Math.floor(Math.random() * a.length)]
const user = { name: pick(NAMES), color: pick(COLORS) }
const sprite = pick(SPRITES)

// Every tile the document may hold, and how it draws: its footprint in
// cells, whether it is ground (part of the cell) or an object standing on
// it, where its chimney is, whether it gives light at night.
const TILES = {
  road: { ground: true }, cable: { ground: true }, bridge: { ground: true }, water: { ground: true },
  grass: { ground: true }, path: { ground: true }, plaza: { ground: true }, cobble: { ground: true },
  house_red: { house: true, chimney: [12, 2] }, house_blue: { house: true, chimney: [12, 2] }, house_orange: { house: true, chimney: [12, 2] },
  victorian_teal: { w: 2, h: 2, house: true, chimney: [26, 1] }, victorian_lilac: { w: 2, h: 2, house: true, chimney: [26, 1] },
  victorian_cream: { w: 2, h: 2, house: true, chimney: [26, 1] },
  grand: { w: 2, h: 3, house: true, chimney: [16, 1] },
  cottage: { w: 2, h: 2, house: true, chimney: [26, 3] }, stone_cottage: { w: 2, h: 2, house: true, chimney: [26, 3] },
  shop: { w: 2, h: 2, shop: true }, shop_blue: { w: 2, h: 2, shop: true }, shop_green: { w: 2, h: 2, shop: true },
  park: { tall: true }, pine: { tall: true }, tree_orange: { tall: true },
  tree_small: {}, tree_orange_small: {}, shrub: {}, mushrooms: {}, flowers: {}, bench: {}, lamp: { light: true }, hydrant: {},
  fence: { auto: true }, sign: {},
}
const ROADS = new Set(["road", "bridge", "cable"])
// The palette: what a tap paints. "walk" moves your character instead.
const TOOLS = [
  ["walk", "Walk", sprite + "_0"], ["erase", "Grass", "grass_1_0"], ["road", "Road", "road_10"], ["cable", "Cable car", "rails_h"],
  ["path", "Path", "path_10"], ["plaza", "Plaza", "plaza_0"], ["water", "Water", "water_0_0"], ["bridge", "Bridge", "bridge_h"],
  ["house_red", "House", "house_red"], ["house_blue", "House", "house_blue"], ["house_orange", "House", "house_orange"],
  ["cottage", "Cottage", "cottage"], ["stone_cottage", "Cottage", "stone_cottage"],
  ["victorian_teal", "Victorian", "victorian_teal"], ["victorian_lilac", "Victorian", "victorian_lilac"], ["victorian_cream", "Victorian", "victorian_cream"],
  ["grand", "Grand house", "grand"], ["shop", "Shop", "shop"], ["shop_blue", "Shop", "shop_blue"], ["shop_green", "Shop", "shop_green"],
  ["park", "Park", "park"], ["pine", "Pine", "pine"], ["tree_orange", "Maple", "tree_orange"], ["shrub", "Shrub", "shrub"],
  ["flowers", "Flowers", "flowers"], ["fence", "Fence", "fence_10"], ["bench", "Bench", "bench"], ["lamp", "Lamp", "lamp"],
  ["hydrant", "Hydrant", "hydrant"], ["sign", "Sign", "sign"],
]

const $ = (id) => document.getElementById(id)
const stage = $("stage"), map = $("map"), overlay = $("overlay"), tintEl = $("tint"), tags = $("tags")
const paletteEl = $("palette"), statusEl = $("status"), presenceEl = $("presence"), offlineEl = $("offline")
const badgeEl = $("offline-badge"), attributionEl = $("attribution"), legendEl = $("legend"), soundEl = $("sound")
const followEl = $("follow"), jumpEl = $("jump"), minimap = $("minimap"), sayForm = $("say-form"), sayInput = $("say")
const inviteEl = document.querySelector(".invite-planner"), lifeEl = document.querySelector(".invite-life")
const documentId = stage.dataset.documentId
const mctx = map.getContext("2d"), octx = overlay.getContext("2d"), tctx = tintEl.getContext("2d"), nctx = minimap.getContext("2d")

const ydoc = new Y.Doc()
const tiles = ydoc.getMap("tiles")
const signs = ydoc.getMap("signs")
const authors = ydoc.getMap("authors")
const claims = ydoc.getMap("claims")
const readings = ydoc.getMap("readings")
const meta = ydoc.getMap("meta")
const consumer = createConsumer()
const provider = new ActionCableProvider(ydoc, consumer, "DocumentChannel", { id: documentId })
const awareness = provider.awareness

const key = (x, y) => `${x},${y}`
const parse = (k) => { const [x, y] = k.split(",").map(Number); return x >= 0 && y >= 0 && x < W && y < H ? [x, y] : null }
const inBounds = (x, y) => x >= 0 && y >= 0 && x < W && y < H
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v))
const now = () => performance.now()

// A tile value as { name, w, h }: "shop@2x2" is a shop over two cells by
// two; "road" is one cell. Null for anything the page could not have written.
function parseTile(value) {
  const m = /^([a-z_]+)(?:@([1-3])x([1-3]))?$/.exec(String(value ?? ""))
  if (!m || !TILES[m[1]]) return null
  return { name: m[1], w: Number(m[2] || 1), h: Number(m[3] || 1) }
}
const sized = (name) => { const t = TILES[name]; return t?.w ? `${name}@${t.w}x${t.h}` : name }

// --- the land ----------------------------------------------------------------
// The bay and the hills come from one seed, the same numbers City::Terrain
// computes in Ruby: a 32-bit hash mixed the same way, value noise blended
// the same way. The seed is the one entry in the meta map; the first page
// to sync a document without one writes it.
const hash32 = (x, y, s) => {
  let h = (Math.imul(x, 374761393) + Math.imul(y, 668265263) + Math.imul(s, 1442695041)) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  h ^= h >>> 16
  return (h >>> 0) / 4294967296
}
function noise(s, x, y, scale) {
  const gx = Math.floor(x / scale), gy = Math.floor(y / scale)
  const fx = x / scale - gx, fy = y / scale - gy
  const ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
  const top = hash32(gx, gy, s) + (hash32(gx + 1, gy, s) - hash32(gx, gy, s)) * ux
  const bottom = hash32(gx, gy + 1, s) + (hash32(gx + 1, gy + 1, s) - hash32(gx, gy + 1, s)) * ux
  return top + (bottom - top) * uy
}
function makeTerrain(seed) {
  if (!Number.isInteger(seed)) return { seed: null, water: () => false, band: () => 0 }
  const shore = new Int16Array(H), band = new Uint8Array(W * H)
  for (let y = 0; y < H; y++) shore[y] = W - 9 - Math.floor(noise(seed + 2, y, 0, 8) * 7)
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    if (x >= shore[y] - 3) continue
    const e = 0.6 * noise(seed, x, y, 16) + 0.4 * noise(seed + 1, x, y, 7)
    band[y * W + x] = e < 0.38 ? 0 : e < 0.5 ? 1 : e < 0.62 ? 2 : 3
  }
  return { seed, water: (x, y) => x >= shore[y], band: (x, y) => band[y * W + x] }
}
let terrain = makeTerrain(meta.get("seed"))

// --- reading the tiles --------------------------------------------------------
// A view is a way to read tiles: the live map, or a timelapse frame. Its
// cover says which anchor stands over each cell a wide building covers.
function makeView(get, entries) {
  const view = { get, entries, cover: new Map() }
  view.rebuild = () => {
    view.cover.clear()
    for (const [k, v] of entries()) {
      const t = parseTile(v)
      if (!t || (t.w === 1 && t.h === 1)) continue
      const cell = parse(k)
      if (!cell) continue
      for (let dy = 0; dy < t.h; dy++) for (let dx = 0; dx < t.w; dx++) if (dx || dy) view.cover.set(key(cell[0] + dx, cell[1] + dy), k)
    }
  }
  view.rebuild()
  return view
}
const live = makeView((k) => tiles.get(k), () => tiles.entries())
let view = live
// The tile standing on a cell: its own, or the wide building over it, with
// where that building is anchored.
function tileAt(v, x, y) {
  if (!inBounds(x, y)) return null
  const k = key(x, y)
  const own = parseTile(v.get(k))
  if (own) return { ...own, ax: x, ay: y, own: true }
  const anchor = v.cover.get(k)
  if (!anchor) return null
  const t = parseTile(v.get(anchor))
  if (!t) return null
  const [ax, ay] = parse(anchor)
  return { ...t, ax, ay, own: false }
}
const nameAt = (v, x, y) => tileAt(v, x, y)?.name
// Water under a cell: painted, or the bay where nothing was built over it.
// A bridge has water under it.
const baseWater = (v, x, y) => { const n = nameAt(v, x, y); return n ? n === "water" || n === "bridge" : terrain.water(x, y) }
const roadAt = (v, x, y) => ROADS.has(nameAt(v, x, y))

// --- the sheet ---------------------------------------------------------------
// One image; drawing a frame is one drawImage at world pixels.
const sheet = new Image()
sheet.src = "/city/tiles.png"
let sheetReady = false
function frame(ctx, name, x, y, flip = 0) {
  const f = F[name]
  if (!f) return
  if (!flip) return ctx.drawImage(sheet, f[0], f[1], f[2], f[3], x, y, f[2], f[3])
  ctx.save()
  ctx.translate(x + (flip === 1 ? f[2] : 0), y + (flip === 2 ? f[3] : 0))
  ctx.scale(flip === 1 ? -1 : 1, flip === 2 ? -1 : 1)
  ctx.drawImage(sheet, f[0], f[1], f[2], f[3], 0, 0, f[2], f[3])
  ctx.restore()
}

// --- the world canvas ---------------------------------------------------------
// The whole town at one pixel per pixel, repainted around what changes.
const world = document.createElement("canvas")
world.width = W * T
world.height = H * T
const wctx = world.getContext("2d")
let waterFrame = 0
const grassVariant = (x, y) => ((x * 31 + y * 17) % 23 === 0 ? 2 : (x * 13 + y * 7) % 29 === 0 ? 1 : 0)
const mask4 = (test, x, y) => (test(x, y - 1) ? 1 : 0) | (test(x + 1, y) ? 2 : 0) | (test(x, y + 1) ? 4 : 0) | (test(x - 1, y) ? 8 : 0)

// A bridge follows the road it carries, and has a tower every fourth cell
// along its span.
function drawBridge(v, x, y) {
  const horizontal = roadAt(v, x - 1, y) || roadAt(v, x + 1, y) || !(roadAt(v, x, y - 1) || roadAt(v, x, y + 1))
  let i = 0
  if (horizontal) for (let bx = x - 1; nameAt(v, bx, y) === "bridge"; bx--) i++
  else for (let by = y - 1; nameAt(v, x, by) === "bridge"; by--) i++
  frame(wctx, `bridge_${horizontal ? "h" : "v"}${i % 4 === 1 ? "_tower" : ""}`, x * T, y * T)
}
function drawGround(v, x, y) {
  const name = nameAt(v, x, y)
  const px = x * T, py = y * T
  if (baseWater(v, x, y)) {
    frame(wctx, `water_${mask4((nx, ny) => inBounds(nx, ny) && !baseWater(v, nx, ny), x, y)}_${waterFrame}`, px, py)
    if (name === "bridge") drawBridge(v, x, y)
    return
  }
  const band = terrain.band(x, y)
  frame(wctx, `grass_${band}_${grassVariant(x, y)}`, px, py)
  if (!name || !TILES[name].ground || name === "grass") {
    const lower = (nx, ny) => inBounds(nx, ny) && !baseWater(v, nx, ny) && terrain.band(nx, ny) < band
    if (lower(x, y + 1)) frame(wctx, "ledge_s", px, py)
    if (lower(x + 1, y)) frame(wctx, "ledge_e", px, py)
    if (lower(x, y - 1)) frame(wctx, "ledge_n", px, py)
    if (lower(x - 1, y)) frame(wctx, "ledge_w", px, py)
  }
  if (name === "road" || name === "cable") {
    frame(wctx, `road_${mask4((nx, ny) => roadAt(v, nx, ny), x, y)}`, px, py)
    if (name === "cable") frame(wctx, (roadAt(v, x, y - 1) || roadAt(v, x, y + 1)) && !(roadAt(v, x - 1, y) || roadAt(v, x + 1, y)) ? "rails_v" : "rails_h", px, py)
  } else if (name === "path" || name === "plaza") {
    frame(wctx, `${name}_${mask4((nx, ny) => nameAt(v, nx, ny) === name, x, y)}`, px, py)
  } else if (name === "cobble") {
    frame(wctx, "cobble", px, py)
  }
}
function drawObject(v, o) {
  const t = TILES[o.name]
  const px = o.ax * T, py = o.ay * T
  if (t.house || t.shop) {
    wctx.fillStyle = "rgba(0,0,0,.22)"
    wctx.fillRect(px + 2, py + 3, o.w * T - 2, o.h * T - 2)
    frame(wctx, o.name, px, py)
  } else if (t.tall) {
    wctx.fillStyle = "rgba(0,0,0,.18)"
    wctx.beginPath(); wctx.ellipse(px + 9, py + 14, 7, 3, 0, 0, Math.PI * 2); wctx.fill()
    frame(wctx, o.name, px, py - T)
  } else if (t.auto) {
    frame(wctx, `${o.name}_${mask4((nx, ny) => nameAt(v, nx, ny) === o.name, o.ax, o.ay)}`, px, py)
  } else {
    frame(wctx, o.name, px, py)
  }
}
// Paint a region of cells, the ground first, then what stands on it in
// order down the map, so a house in front covers the one behind.
function drawRegion(v, x0, y0, x1, y1) {
  x0 = clamp(x0, 0, W - 1); y0 = clamp(y0, 0, H - 1); x1 = clamp(x1, 0, W - 1); y1 = clamp(y1, 0, H - 1)
  wctx.save()
  wctx.beginPath(); wctx.rect(x0 * T, y0 * T, (x1 - x0 + 1) * T, (y1 - y0 + 1) * T); wctx.clip()
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) drawGround(v, x, y)
  const objects = []
  for (let y = Math.max(0, y0 - 3); y <= y1; y++) for (let x = Math.max(0, x0 - 2); x <= x1; x++) {
    const own = parseTile(v.get(key(x, y)))
    if (own && !TILES[own.name].ground) objects.push({ ...own, ax: x, ay: y })
  }
  objects.sort((a, b) => (a.ay + a.h) - (b.ay + b.h) || a.ax - b.ax)
  for (const o of objects) drawObject(v, o)
  wctx.restore()
}
const drawAll = (v = view) => drawRegion(v, 0, 0, W - 1, H - 1)

// Cells that changed wait for the next frame and are repainted together,
// with a margin for the neighbours whose edges depend on them and for the
// tall buildings anchored above.
let dirty = null
function markDirty(x, y, r = 3) {
  if (!dirty) dirty = { x0: x - r, y0: y - r, x1: x + r, y1: y + r }
  else { dirty.x0 = Math.min(dirty.x0, x - r); dirty.y0 = Math.min(dirty.y0, y - r); dirty.x1 = Math.max(dirty.x1, x + r); dirty.y1 = Math.max(dirty.y1, y + r) }
  requestFrame()
}
function flushDirty() {
  if (!dirty) return
  const d = dirty
  dirty = null
  if ((d.x1 - d.x0 + 1) * (d.y1 - d.y0 + 1) > 3000) drawAll()
  else drawRegion(view, d.x0, d.y0, d.x1, d.y1)
  minimapDirty = true
}

// --- the camera --------------------------------------------------------------
// World pixels at the top-left of the viewport, and the zoom. Drag to pan,
// pinch or scroll to zoom, or follow someone.
const cam = { x: 0, y: 0, zoom: 2 }
let following = null // null, "planner", or "me"
let dpr = 1
let stageW = 0, stageH = 0
function fit() {
  stageW = stage.clientWidth
  stageH = Math.max(240, Math.min(Math.round(stageW * 0.72), window.innerHeight - 180))
  stage.style.height = `${stageH}px`
  dpr = Math.min(window.devicePixelRatio || 1, 3)
  for (const c of [map, overlay, tintEl]) { c.width = Math.round(stageW * dpr); c.height = Math.round(stageH * dpr) }
  clampCamera()
  requestFrame(true)
}
function clampCamera() {
  cam.zoom = clamp(cam.zoom, 0.5, 4)
  const vw = stageW / cam.zoom, vh = stageH / cam.zoom
  cam.x = vw >= W * T ? (W * T - vw) / 2 : clamp(cam.x, 0, W * T - vw)
  cam.y = vh >= H * T ? (H * T - vh) / 2 : clamp(cam.y, 0, H * T - vh)
  cam.x = Math.round(cam.x * cam.zoom) / cam.zoom
  cam.y = Math.round(cam.y * cam.zoom) / cam.zoom
}
function panBy(dx, dy) { cam.x += dx; cam.y += dy; following = null; clampCamera(); requestFrame(true) }
function zoomAt(zoom, sx, sy) {
  const wx = cam.x + sx / cam.zoom, wy = cam.y + sy / cam.zoom
  cam.zoom = clamp(zoom, 0.5, 4)
  cam.x = wx - sx / cam.zoom
  cam.y = wy - sy / cam.zoom
  clampCamera()
  requestFrame(true)
}
function centerOn(cx, cy) {
  cam.x = (cx + 0.5) * T - stageW / cam.zoom / 2
  cam.y = (cy + 0.5) * T - stageH / cam.zoom / 2
  clampCamera()
  requestFrame(true)
}
function follow(what) {
  following = what
  followEl.setAttribute("aria-pressed", String(what === "planner"))
}
const toScreen = (wx, wy) => [(wx - cam.x) * cam.zoom, (wy - cam.y) * cam.zoom]
const toWorld = (sx, sy) => [cam.x + sx / cam.zoom, cam.y + sy / cam.zoom]
const visible = () => {
  const [x0, y0] = toWorld(0, 0), [x1, y1] = toWorld(stageW, stageH)
  return { x0: clamp(Math.floor(x0 / T), 0, W - 1), y0: clamp(Math.floor(y0 / T), 0, H - 1), x1: clamp(Math.ceil(x1 / T), 0, W - 1), y1: clamp(Math.ceil(y1 / T), 0, H - 1) }
}

// --- me ----------------------------------------------------------------------
let tool = "house_red"
let pos = { x: 30 + Math.floor(Math.random() * 30), y: 30 + Math.floor(Math.random() * 30) }
const mine = { say: null, hop: 0 }
const presence = () => ({ user, sprite, pos, tool, say: mine.say, hop: mine.hop })
// Presence goes out at most every 80 ms, whatever changed meanwhile.
let publishTimer = null
function publish() {
  publishTimer ??= setTimeout(() => { publishTimer = null; awareness.setLocalState(presence()) }, 80)
}
awareness.setLocalState(presence())

function setTool(name) {
  tool = name
  for (const b of paletteEl.children) b.setAttribute("aria-pressed", String(b.dataset.tool === name))
  publish()
}
function moveTo(x, y) {
  if (!inBounds(x, y)) return
  pos = { x, y }
  publish()
  if (following === "me" || !following) keepInView(x, y)
  requestFrame()
}
function keepInView(x, y) {
  const [sx, sy] = toScreen((x + 0.5) * T, (y + 0.5) * T)
  const m = 48
  if (sx < m || sy < m || sx > stageW - m || sy > stageH - m) centerOn(x, y)
}
function say(text) {
  text = String(text ?? "").trim().slice(0, 60)
  if (!text) return
  mine.say = { text, at: Date.now() }
  publish()
  setTimeout(() => { if (mine.say?.text === text) { mine.say = null; publish() } }, 8000)
  requestFrame()
}
function hop() {
  mine.hop = Date.now()
  publish()
  sound.play("hop")
  requestFrame()
}

for (const [name, label, icon] of TOOLS) {
  const b = document.createElement("button")
  b.type = "button"
  b.dataset.tool = name
  b.title = label
  const c = document.createElement("canvas")
  c.width = c.height = 32
  b.appendChild(c)
  b.appendChild(document.createTextNode(label))
  b.addEventListener("click", () => setTool(name))
  sheet.addEventListener("load", () => {
    const cc = c.getContext("2d")
    cc.imageSmoothingEnabled = false
    const f = F[icon]
    if (!TILES[name]?.ground && name !== "walk" && name !== "erase") for (const [gx, gy] of [[0, 0], [16, 0], [0, 16], [16, 16]]) frame(cc, "grass_1_0", gx, gy)
    const s = Math.min(32 / f[2], 32 / f[3])
    cc.save(); cc.scale(s, s); frame(cc, icon, (32 / s - f[2]) / 2, (32 / s - f[3]) / 2); cc.restore()
  })
  paletteEl.appendChild(b)
}

// --- painting ----------------------------------------------------------------
// Pointer events are coalesced into one transaction every 40 ms, so a drag is
// one update per tick rather than one per cell. The tile and its author go in
// the same transaction; erasing takes both out, and a sign's text with them.
// A wide building clears whatever stood under its footprint.
const pending = new Map()
let flush = null
function paint(x, y, name = tool) {
  if (!inBounds(x, y) || name === "walk" || name === "sign") return
  const t = TILES[name]
  if (t?.w && (x + t.w > W || y + t.h > H)) return
  pending.set(key(x, y), name)
  flush ??= setTimeout(() => {
    flush = null
    ydoc.transact(() => { for (const [k, name] of pending) paintOne(k, name) })
    pending.clear()
    sound.play("place")
  }, 40)
}
function remove(k) { tiles.delete(k); authors.delete(k); signs.delete(k); readings.delete(k) }
function paintOne(k, name) {
  const [x, y] = parse(k)
  const under = tileAt(live, x, y)
  if (name === "erase") {
    if (under) remove(key(under.ax, under.ay))
    else if (terrain.water(x, y)) { tiles.set(k, "grass"); authors.set(k, `h:${user.name}`) }
    return
  }
  if (tiles.get(k) === sized(name)) return
  const t = TILES[name]
  const w = t.w || 1, h = t.h || 1
  for (let dy = 0; dy < h; dy++) for (let dx = 0; dx < w; dx++) {
    const c = tileAt(live, x + dx, y + dy)
    if (c) remove(key(c.ax, c.ay))
  }
  tiles.set(k, sized(name))
  authors.set(k, `h:${user.name}`)
  live.rebuild()
}
function placeSign(x, y, text) {
  if (!inBounds(x, y)) return
  const k = key(x, y)
  text ??= prompt("What should the sign say? The planner reads PARK, SHOP, ROAD, BRIDGE, NO BUILD, and CLEAR.", signs.get(k) || "")
  if (text === null) return
  ydoc.transact(() => {
    const under = tileAt(live, x, y)
    if (under && !under.own) remove(key(under.ax, under.ay))
    tiles.set(k, "sign")
    authors.set(k, `h:${user.name}`)
    signs.set(k, text.trim())
    readings.delete(k) // a new text is read afresh
  })
  sound.play("place")
}

// --- pointers: paint, pan, pinch, tap --------------------------------------
// One finger or the mouse paints with a tile tool and pans with the walk
// tool (a tap walks); two fingers pan and pinch; the wheel zooms; the middle
// or right button, or a held space bar, pans with any tool.
const pointers = new Map()
let gesture = null
let spaceHeld = false
const cellAt = (sx, sy) => { const [wx, wy] = toWorld(sx, sy); return [Math.floor(wx / T), Math.floor(wy / T)] }
const local = (e) => { const r = stage.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] }
stage.addEventListener("contextmenu", (e) => e.preventDefault())
overlay.addEventListener("pointerdown", (e) => {
  e.preventDefault()
  overlay.setPointerCapture(e.pointerId)
  const [sx, sy] = local(e)
  pointers.set(e.pointerId, { x: sx, y: sy })
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()]
    gesture = { kind: "pinch", dist: Math.hypot(a.x - b.x, a.y - b.y), zoom: cam.zoom, mid: [(a.x + b.x) / 2, (a.y + b.y) / 2], cam: { x: cam.x, y: cam.y } }
    return
  }
  const pan = e.button === 1 || e.button === 2 || spaceHeld || tool === "walk"
  gesture = { kind: pan ? "maybe-pan" : "paint", sx, sy, cam: { x: cam.x, y: cam.y }, moved: false }
  if (gesture.kind === "paint") {
    if (tool === "sign") return placeSign(...cellAt(sx, sy))
    paint(...cellAt(sx, sy))
    const t = TILES[tool]
    if (t?.w) gesture.kind = "placed" // a wide building goes down once per tap
  }
})
overlay.addEventListener("pointermove", (e) => {
  if (!pointers.has(e.pointerId) || !gesture) return
  const [sx, sy] = local(e)
  pointers.set(e.pointerId, { x: sx, y: sy })
  if (gesture.kind === "pinch" && pointers.size === 2) {
    const [a, b] = [...pointers.values()]
    const dist = Math.hypot(a.x - b.x, a.y - b.y)
    const mid = [(a.x + b.x) / 2, (a.y + b.y) / 2]
    cam.x = gesture.cam.x; cam.y = gesture.cam.y; cam.zoom = gesture.zoom
    zoomAt(gesture.zoom * (dist / gesture.dist), gesture.mid[0], gesture.mid[1])
    panBy((gesture.mid[0] - mid[0]) / cam.zoom, (gesture.mid[1] - mid[1]) / cam.zoom)
    return
  }
  if (gesture.kind === "maybe-pan" || gesture.kind === "pan") {
    if (Math.hypot(sx - gesture.sx, sy - gesture.sy) > 6) gesture.kind = "pan"
    if (gesture.kind === "pan") { cam.x = gesture.cam.x - (sx - gesture.sx) / cam.zoom; cam.y = gesture.cam.y - (sy - gesture.sy) / cam.zoom; following = null; clampCamera(); requestFrame(true) }
    return
  }
  if (gesture.kind === "paint") paint(...cellAt(sx, sy))
})
function pointerEnd(e) {
  const [sx, sy] = local(e)
  pointers.delete(e.pointerId)
  if (!gesture) return
  if (gesture.kind === "maybe-pan") {
    const [x, y] = cellAt(sx, sy)
    if (tool === "walk" && e.button === 0) { if (nameAt(live, x, y) === "sign") placeSign(x, y); else moveTo(x, y) }
  }
  if (pointers.size === 0) gesture = null
  else if (gesture.kind === "pinch") gesture = { kind: "done" }
}
overlay.addEventListener("pointerup", pointerEnd)
overlay.addEventListener("pointercancel", pointerEnd)
overlay.addEventListener("wheel", (e) => {
  e.preventDefault()
  const [sx, sy] = local(e)
  zoomAt(cam.zoom * Math.exp(-e.deltaY * 0.0015), sx, sy)
  following = null
}, { passive: false })

const MOVES = { ArrowUp: [0, -1], ArrowDown: [0, 1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] }
window.addEventListener("keydown", (e) => {
  if (e.target.matches("input, textarea")) return
  if (MOVES[e.key]) { e.preventDefault(); return moveTo(pos.x + MOVES[e.key][0], pos.y + MOVES[e.key][1]) }
  if (e.key === " ") { e.preventDefault(); if (!e.repeat) { spaceHeld = true; hop() } }
  if (e.key === "+" || e.key === "=") zoomAt(cam.zoom * 1.25, stageW / 2, stageH / 2)
  if (e.key === "-") zoomAt(cam.zoom / 1.25, stageW / 2, stageH / 2)
})
window.addEventListener("keyup", (e) => { if (e.key === " ") spaceHeld = false })
let lastTap = 0
overlay.addEventListener("pointerup", (e) => {
  if (e.pointerType !== "touch") return
  const t = now()
  if (t - lastTap < 300) hop()
  lastTap = t
})
sayForm.addEventListener("submit", (e) => { e.preventDefault(); say(sayInput.value); sayInput.value = ""; sayInput.blur() })
jumpEl.addEventListener("click", () => { follow(null); centerOn(pos.x, pos.y) })
followEl.addEventListener("click", () => { follow(following === "planner" ? null : "planner"); requestFrame() })
minimap.addEventListener("pointerdown", (e) => {
  const r = minimap.getBoundingClientRect()
  follow(null)
  centerOn(Math.floor(((e.clientX - r.left) / r.width) * W), Math.floor(((e.clientY - r.top) / r.height) * H))
})

// --- the town's life, from awareness ----------------------------------------
// Everyone's position eases from where it was to where it is now over one
// tick, so a cell-per-tick walk reads as a walk. Movers are keyed by who
// they are; a mover not seen for two ticks is dropped.
const movers = new Map() // id -> { x, y, fx, fy, tx, ty, t0, face, ... }
function mover(id, tx, ty, extra = {}) {
  let m = movers.get(id)
  if (!m) { m = { x: tx, y: ty, fx: tx, fy: ty, tx, ty, t0: now(), face: 1 }; movers.set(id, m) }
  else if (m.tx !== tx || m.ty !== ty) {
    if (Math.abs(m.tx - tx) + Math.abs(m.ty - ty) > 12) { m.x = m.fx = tx; m.y = m.fy = ty } else { m.fx = m.x; m.fy = m.y }
    if (tx !== m.tx) m.face = tx > m.tx ? 1 : -1
    m.tx = tx; m.ty = ty; m.t0 = now()
  }
  Object.assign(m, extra)
  m.seen = now()
  return m
}
function ease(m, ms = LIFE_TICK) {
  const t = clamp((now() - m.t0) / ms, 0, 1)
  m.x = m.fx + (m.tx - m.fx) * t
  m.y = m.fy + (m.ty - m.fy) * t
  m.moving = t < 1 && (m.fx !== m.tx || m.fy !== m.ty)
  return m
}
let life = null // the latest CityLife state, and when it came
let clockBase = { clock: 0.35, at: now() }
function clockNow() { return (clockBase.clock + (now() - clockBase.at) / DAY) % 1 }
const lifeState = () => [...awareness.getStates().values()].find((s) => s?.life)
const plannerState = () => [...awareness.getStates().values()].find((s) => s?.planner)

function people() {
  const out = []
  for (const [id, s] of awareness.getStates()) {
    if (s?.user && s.pos && inBounds(s.pos.x, s.pos.y) && !s.life) out.push({ ...s, id, me: id === awareness.clientID })
  }
  return out
}

// Greetings: two characters side by side for two seconds both wave.
const adjacentSince = new Map()
const waves = new Map() // id -> until
let lastGreetCheck = 0
function checkGreetings() {
  if (now() - lastGreetCheck < 250) return
  lastGreetCheck = now()
  const folk = people()
  const seen = new Set()
  for (let i = 0; i < folk.length; i++) for (let j = i + 1; j < folk.length; j++) {
    const a = folk[i], b = folk[j]
    if (Math.abs(a.pos.x - b.pos.x) + Math.abs(a.pos.y - b.pos.y) !== 1) continue
    const k = `${a.id}:${b.id}`
    seen.add(k)
    const since = adjacentSince.get(k) ?? (adjacentSince.set(k, now()), now())
    if (now() - since >= 2000 && !adjacentSince.get(`${k}:waved`)) {
      adjacentSince.set(`${k}:waved`, true)
      waves.set(a.id, now() + 1800); waves.set(b.id, now() + 1800)
    }
  }
  for (const k of [...adjacentSince.keys()]) if (!k.endsWith(":waved") && !seen.has(k)) { adjacentSince.delete(k); adjacentSince.delete(`${k}:waved`) }
}

// --- the overlay: everything that moves ---------------------------------------
const flashes = new Map() // cell -> when it arrived, after a reconnect
let flashed = 0
let attribution = false
const stats = { frames: 0, total: 0, max: 0, recent: [] }
function drawOverlay() {
  const t0 = now()
  octx.setTransform(dpr * cam.zoom, 0, 0, dpr * cam.zoom, -cam.x * dpr * cam.zoom, -cam.y * dpr * cam.zoom)
  octx.imageSmoothingEnabled = false
  const vis = visible()
  octx.clearRect(cam.x, cam.y, stageW / cam.zoom, stageH / cam.zoom)
  const onScreen = (x, y) => x >= vis.x0 - 3 && x <= vis.x1 + 1 && y >= vis.y0 - 3 && y <= vis.y1 + 1
  if (attribution) {
    for (const [k, who] of authors.entries()) {
      const cell = parse(k)
      if (!cell || !onScreen(...cell)) continue
      const t = parseTile(tiles.get(k))
      if (!t) continue
      octx.fillStyle = who === "a:planner" ? "rgba(227,134,40,.55)" : who === "a:mayor" ? "rgba(168,85,247,.5)" : "rgba(37,99,235,.45)"
      octx.fillRect(cell[0] * T, cell[1] * T, t.w * T, t.h * T)
    }
  }
  // the planner's claims: cones, and a dashed line round the lot
  if (claims.size) {
    let x0 = W, y0 = H, x1 = 0, y1 = 0
    for (const k of claims.keys()) {
      const c = parse(k)
      if (!c) continue
      x0 = Math.min(x0, c[0]); y0 = Math.min(y0, c[1]); x1 = Math.max(x1, c[0]); y1 = Math.max(y1, c[1])
      if (onScreen(...c)) frame(octx, "cone", c[0] * T, c[1] * T)
    }
    octx.save()
    octx.strokeStyle = "#ff9f1c"; octx.lineWidth = 2.5 / cam.zoom; octx.setLineDash([6 / cam.zoom, 4 / cam.zoom])
    octx.strokeRect(x0 * T - 2, y0 * T - 2, (x1 - x0 + 1) * T + 4, (y1 - y0 + 1) * T + 4)
    octx.restore()
  }
  // tiles that arrived from the other side of a reconnect flash white
  for (const [k, at] of flashes) {
    const age = now() - at
    if (age > 1200) { flashes.delete(k); continue }
    const c = parse(k)
    if (!c) continue
    octx.fillStyle = `rgba(255,255,255,${(0.85 * (1 - age / 1200)).toFixed(3)})`
    octx.fillRect(c[0] * T, c[1] * T, T, T)
  }
  drawStreetLabels(vis)
  drawSmoke(vis)
  // the townsfolk, the traffic, and everyone here, in order down the map
  const sprites = []
  const t = now()
  if (life) {
    for (const p of life.peds) {
      const m = ease(mover(`p:${p[0]}`, p[2], p[3], { say: p[5], sprite: p[1] }))
      m.face = p[4] || m.face
      sprites.push({ y: m.y, draw: () => drawPerson(`ped_${m.sprite}`, m, 0, m.say ? { text: m.say } : null, p[0]) })
    }
    for (const [i, c] of life.cars.entries()) {
      const m = ease(mover(`c:${i}`, c[0], c[1], { dx: c[2], dy: c[3], kind: c[4] }))
      sprites.push({ y: m.y, draw: () => frame(octx, m.kind === "tram" ? (m.dx ? "tram_h" : "tram_v") : `car_${m.dx ? "h" : "v"}_${m.kind}`, m.x * T, m.y * T, m.dx < 0 ? 1 : m.dy < 0 ? 2 : 0) })
    }
    for (const [i, b] of life.boats.entries()) {
      const m = ease(mover(`b:${i}`, b[0], b[1], {}), LIFE_TICK * 2)
      const bob = Math.sin(t / 600 + i) * 1
      sprites.push({ y: m.y, draw: () => frame(octx, b[2] < 0 ? "boat" : "boat_flip", m.x * T, m.y * T + bob) })
    }
  }
  for (const s of people()) {
    const m = ease(mover(`u:${s.id}`, s.pos.x, s.pos.y, {}), 260)
    const hopAge = Date.now() - (s.hop || 0)
    const lift = hopAge < 450 ? -12 * Math.sin((hopAge / 450) * Math.PI) : 0
    const bubble = s.say?.text && Date.now() - s.say.at < 8000 ? { text: s.say.text } : waves.get(s.id) > t ? { wave: true } : null
    sprites.push({ y: m.y + 0.01, draw: () => drawPerson(s.planner ? "planner" : SPRITES.includes(s.sprite) ? s.sprite : SPRITES[0], m, lift, bubble) })
  }
  sprites.sort((a, b) => a.y - b.y)
  for (const s of sprites) s.draw()
  if (life) for (const [i, g] of life.gulls.entries()) {
    const m = ease(mover(`g:${i}`, g[0], g[1], { dx: g[2] }))
    if (!onScreen(m.x, m.y)) continue
    octx.fillStyle = "rgba(0,0,0,.12)"; octx.beginPath(); octx.ellipse(m.x * T + 8, m.y * T + 10, 4, 2, 0, 0, Math.PI * 2); octx.fill()
    frame(octx, `gull_${Math.floor(t / 220 + i) % 2}`, m.x * T, m.y * T - 18 + Math.sin(t / 500 + i) * 2, m.dx < 0 ? 1 : 0)
  }
  for (const [id, m] of movers) if (now() - m.seen > LIFE_TICK * 4) movers.delete(id)
  const ms = now() - t0
  stats.frames++; stats.total += ms; stats.max = Math.max(stats.max, ms); stats.recent.push(ms); if (stats.recent.length > 120) stats.recent.shift()
}
function drawPerson(base, m, lift, bubble, label) {
  const walkFrame = m.moving ? 1 + (Math.floor(now() / 140) % 2) : 0
  const px = m.x * T, py = m.y * T + lift
  octx.fillStyle = "rgba(0,0,0,.2)"; octx.beginPath(); octx.ellipse(m.x * T + 8, m.y * T + 14, 5, 2, 0, 0, Math.PI * 2); octx.fill()
  frame(octx, `${base}_${walkFrame}`, px, py, m.face < 0 ? 1 : 0)
  if (label) {
    octx.font = "6px system-ui, sans-serif"; octx.textAlign = "center"; octx.fillStyle = "rgba(63,38,49,.85)"
    octx.fillText(label, px + 8, py + 2)
  }
  if (bubble) drawBubble(px + 8, py - 2, bubble)
}
function drawBubble(x, y, { text, wave }) {
  octx.save()
  octx.font = "bold 7px system-ui, sans-serif"; octx.textAlign = "center"; octx.textBaseline = "middle"
  const w = wave ? 18 : Math.min(120, octx.measureText(text).width + 8), h = wave ? 18 : 12
  const bx = x - w / 2, by = y - h - 5
  octx.fillStyle = "#fff"; octx.strokeStyle = "#3f2631"; octx.lineWidth = 1
  octx.beginPath(); octx.roundRect(bx, by, w, h, 3); octx.fill(); octx.stroke()
  octx.beginPath(); octx.moveTo(x - 3, by + h); octx.lineTo(x, by + h + 4); octx.lineTo(x + 3, by + h); octx.closePath(); octx.fill()
  octx.beginPath(); octx.moveTo(x - 3, by + h); octx.lineTo(x, by + h + 4); octx.lineTo(x + 3, by + h); octx.stroke()
  octx.fillStyle = "#fff"; octx.fillRect(x - 2.5, by + h - 1, 5, 1.5)
  if (wave) frame(octx, "wave", bx + 1, by + 1)
  else { octx.fillStyle = "#3f2631"; octx.fillText(text.length > 28 ? text.slice(0, 27) + "…" : text, x, by + h / 2 + 0.5) }
  octx.restore()
}
// Chimney smoke: three puffs a house, rising and thinning, from the houses
// CityLife says are lit.
function drawSmoke(vis) {
  if (!life?.smoke?.length) return
  const t = now()
  for (const k of life.smoke) {
    const c = parse(k)
    const tile = c && parseTile(tiles.get(k))
    if (!tile || !TILES[tile.name]?.chimney || c[0] < vis.x0 - 2 || c[0] > vis.x1 || c[1] < vis.y0 - 2 || c[1] > vis.y1 + 1) continue
    const [cx, cy] = TILES[tile.name].chimney
    const x = c[0] * T + cx, y = c[1] * T + cy
    const seed = (c[0] * 7 + c[1] * 13) % 1000
    for (let i = 0; i < 3; i++) {
      const p = ((t + seed * 10) / 1500 + i / 3) % 1
      octx.fillStyle = `rgba(235,235,245,${(0.55 * (1 - p)).toFixed(3)})`
      octx.beginPath(); octx.arc(x + Math.sin(p * 7 + i) * 2, y - p * 16, 1.5 + p * 3, 0, Math.PI * 2); octx.fill()
    }
  }
}
// The mayor's names, and anyone's, along the road they name: a sign that
// asks for nothing is a name; its label runs along the roads beside it.
let labels = null
function computeLabels() {
  labels = []
  for (const [k, text] of signs.entries()) {
    const cell = parse(k)
    const t = String(text || "").trim()
    if (!cell || !t || nameAt(live, cell[0], cell[1]) !== "sign" || isInstruction(t) || isInstruction(readings.get(k))) continue
    const start = [[cell[0], cell[1] - 1], [cell[0] + 1, cell[1]], [cell[0], cell[1] + 1], [cell[0] - 1, cell[1]]].find(([x, y]) => roadAt(live, x, y))
    if (!start) continue
    const seen = new Set([key(...start)]), queue = [start], cells = []
    while (queue.length && cells.length < 40) {
      const [x, y] = queue.shift()
      cells.push([x, y])
      for (const [nx, ny] of [[x, y - 1], [x + 1, y], [x, y + 1], [x - 1, y]]) {
        const nk = key(nx, ny)
        if (!seen.has(nk) && roadAt(live, nx, ny) && Math.abs(nx - cell[0]) + Math.abs(ny - cell[1]) < 12) { seen.add(nk); queue.push([nx, ny]) }
      }
    }
    const mx = cells.reduce((a, c) => a + c[0], 0) / cells.length, my = cells.reduce((a, c) => a + c[1], 0) / cells.length
    const vx = cells.reduce((a, c) => a + (c[0] - mx) ** 2, 0), vy = cells.reduce((a, c) => a + (c[1] - my) ** 2, 0)
    labels.push({ x: (mx + 0.5) * T, y: (my + 0.5) * T, vertical: vy > vx, text: t.slice(0, 24) })
  }
}
const isInstruction = (text) => /NO BUILD|\b(PARK|SHOP|ROAD|BRIDGE|CLEAR)\b/.test(String(text || "").toUpperCase())
function drawStreetLabels(vis) {
  if (!labels) computeLabels()
  for (const l of labels) {
    if (l.x / T < vis.x0 - 8 || l.x / T > vis.x1 + 8 || l.y / T < vis.y0 - 8 || l.y / T > vis.y1 + 8) continue
    octx.save()
    octx.translate(l.x, l.y)
    if (l.vertical) octx.rotate(-Math.PI / 2)
    octx.font = "bold 7px system-ui, sans-serif"; octx.textAlign = "center"; octx.textBaseline = "middle"
    octx.lineWidth = 2; octx.strokeStyle = "rgba(63,38,49,.9)"; octx.lineJoin = "round"
    octx.strokeText(l.text.toUpperCase(), 0, 0)
    octx.fillStyle = "#fff8e1"; octx.fillText(l.text.toUpperCase(), 0, 0)
    octx.restore()
  }
}

// --- the time of day -----------------------------------------------------------
// A tint over everything, deep blue at night and warm at dusk and dawn,
// with pools of light where the lamps and the windows are.
let tintDrawn = { clock: -1, x: -1, y: -1, zoom: -1 }
function drawTint() {
  const c = clockNow()
  const daylight = clamp((Math.cos((c - 0.5) * Math.PI * 2) + 0.6) / 1.2, 0, 1)
  const step = Math.round(daylight * 40)
  if (tintDrawn.clock === step && tintDrawn.x === cam.x && tintDrawn.y === cam.y && tintDrawn.zoom === cam.zoom && !tintDrawn.dirty) return
  tintDrawn = { clock: step, x: cam.x, y: cam.y, zoom: cam.zoom, dirty: false }
  tctx.setTransform(1, 0, 0, 1, 0, 0)
  tctx.clearRect(0, 0, tintEl.width, tintEl.height)
  const night = 1 - daylight
  const warm = Math.exp(-(((c - 0.78) / 0.05) ** 2)) + Math.exp(-(((c - 0.24) / 0.05) ** 2))
  if (warm > 0.02) { tctx.fillStyle = `rgba(255,130,50,${(0.18 * warm).toFixed(3)})`; tctx.fillRect(0, 0, tintEl.width, tintEl.height) }
  if (night < 0.05) return
  tctx.fillStyle = `rgba(14,22,70,${(0.6 * night).toFixed(3)})`
  tctx.fillRect(0, 0, tintEl.width, tintEl.height)
  tctx.setTransform(dpr * cam.zoom, 0, 0, dpr * cam.zoom, -cam.x * dpr * cam.zoom, -cam.y * dpr * cam.zoom)
  tctx.globalCompositeOperation = "destination-out"
  const vis = visible()
  for (let y = Math.max(0, vis.y0 - 3); y <= vis.y1; y++) for (let x = Math.max(0, vis.x0 - 2); x <= vis.x1; x++) {
    const t = parseTile(tiles.get(key(x, y)))
    if (!t) continue
    const spec = TILES[t.name]
    if (spec.light) pool(x * T + 8, y * T + 3, 26, night)
    else if (spec.house || spec.shop) pool(x * T + t.w * T / 2, y * T + t.h * T * 0.7, 12 + t.w * 6, night * 0.7)
  }
  tctx.globalCompositeOperation = "source-over"
}
function pool(x, y, r, strength) {
  const g = tctx.createRadialGradient(x, y, 0, x, y, r)
  g.addColorStop(0, `rgba(255,255,255,${(0.95 * strength).toFixed(3)})`)
  g.addColorStop(1, "rgba(255,255,255,0)")
  tctx.fillStyle = g
  tctx.beginPath(); tctx.arc(x, y, r, 0, Math.PI * 2); tctx.fill()
}

// --- the frame loop ---------------------------------------------------------------
// One frame per animation frame while something moves; the ground is
// blitted only when the camera or the world changed.
let frameQueued = false
let groundDirty = true
let minimapDirty = true
let minimapAt = 0
function requestFrame(ground = false) {
  if (ground) groundDirty = true
  if (frameQueued) return
  frameQueued = true
  requestAnimationFrame(renderFrame)
}
function renderFrame() {
  frameQueued = false
  if (!sheetReady) return
  if (following === "planner") {
    const entry = [...awareness.getStates().entries()].find(([, s]) => s?.planner && s.pos)
    if (entry) { const m = movers.get(`u:${entry[0]}`); centerOnSoft(m ? m.x : entry[1].pos.x, m ? m.y : entry[1].pos.y) }
  }
  if (dirty) { flushDirty(); groundDirty = true }
  if (groundDirty) {
    groundDirty = false
    mctx.setTransform(1, 0, 0, 1, 0, 0)
    mctx.imageSmoothingEnabled = false
    mctx.fillStyle = "#3b6f96"
    mctx.fillRect(0, 0, map.width, map.height)
    const sx = Math.max(0, cam.x), sy = Math.max(0, cam.y)
    const sw = Math.min(W * T - sx, stageW / cam.zoom), sh = Math.min(H * T - sy, stageH / cam.zoom)
    mctx.drawImage(world, sx, sy, sw, sh, (sx - cam.x) * cam.zoom * dpr, (sy - cam.y) * cam.zoom * dpr, sw * cam.zoom * dpr, sh * cam.zoom * dpr)
  }
  checkGreetings()
  drawOverlay()
  drawTint()
  renderTags()
  if (minimapDirty && now() - minimapAt > 800) drawMinimap()
  const animating = life || movers.size || flashes.size || claims.size || Date.now() - mine.hop < 500
  if (animating || following === "planner") requestFrame()
}
function centerOnSoft(cx, cy) {
  const tx = (cx + 0.5) * T - stageW / cam.zoom / 2, ty = (cy + 0.5) * T - stageH / cam.zoom / 2
  cam.x += (tx - cam.x) * 0.08; cam.y += (ty - cam.y) * 0.08
  clampCamera()
  groundDirty = true
}
function drawMinimap() {
  minimapDirty = false
  minimapAt = now()
  nctx.imageSmoothingEnabled = true
  nctx.drawImage(world, 0, 0, W, H)
  nctx.strokeStyle = "#fff"; nctx.lineWidth = 1
  nctx.strokeRect(cam.x / T, cam.y / T, stageW / cam.zoom / T, stageH / cam.zoom / T)
  nctx.fillStyle = user.color; nctx.fillRect(pos.x - 1, pos.y - 1, 3, 3)
  const p = plannerState()
  if (p?.pos) { nctx.fillStyle = "#e38628"; nctx.fillRect(p.pos.x - 1, p.pos.y - 1, 3, 3) }
}
setInterval(() => { waterFrame ^= 1; const vis = visible(); for (let y = vis.y0; y <= vis.y1; y++) for (let x = vis.x0; x <= vis.x1; x++) if (baseWater(view, x, y)) drawGround(view, x, y); requestFrame(true) }, 700)
setInterval(() => { minimapDirty = true; tintDrawn.dirty = true; requestFrame() }, 1000)

// Name tags and sign text are DOM, placed over the stage, so they stay
// crisp at any zoom. The stage clips what the camera does not show.
function renderTags() {
  const els = []
  const place = (el, wx, wy) => {
    const [sx, sy] = toScreen(wx, wy)
    el.style.left = `${sx}px`; el.style.top = `${sy}px`
    els.push(el)
  }
  for (const s of people()) {
    const m = movers.get(`u:${s.id}`)
    const el = document.createElement("div")
    el.className = "tag" + (s.me ? " me" : "")
    el.style.background = s.user.color
    el.textContent = s.user.name + (s.status ? ` · ${s.status}` : "")
    place(el, ((m ? m.x : s.pos.x) + 0.5) * T, (m ? m.y : s.pos.y) * T + 2)
  }
  for (const [k, text] of signs.entries()) {
    const cell = parse(k)
    if (!cell || tiles.get(k) !== "sign" || !text) continue
    const el = document.createElement("div")
    el.className = "sign-text"
    const reading = readings.get(k)
    el.textContent = String(text).slice(0, 14) + (reading && reading !== "none" ? ` → ${reading}` : "")
    place(el, (cell[0] + 0.5) * T, cell[1] * T)
  }
  tags.replaceChildren(...els)
}

// --- sound --------------------------------------------------------------------
// Four small sounds, synthesised here, off until the toggle: a blip when a
// tile goes down, a hop, a chime when the planner finishes a road, a bell
// when the mayor names something.
const sound = {
  on: false, ctx: null,
  toggle() {
    this.on = !this.on
    if (this.on && !this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)()
    if (this.on) this.ctx.resume()
    soundEl.setAttribute("aria-pressed", String(this.on))
    soundEl.textContent = this.on ? "Sound on" : "Sound off"
  },
  tone(freq, at, dur, type = "sine", gain = 0.08, slide = 0) {
    const o = this.ctx.createOscillator(), g = this.ctx.createGain()
    o.type = type; o.frequency.setValueAtTime(freq, at)
    if (slide) o.frequency.exponentialRampToValueAtTime(slide, at + dur)
    g.gain.setValueAtTime(gain, at); g.gain.exponentialRampToValueAtTime(0.0005, at + dur)
    o.connect(g).connect(this.ctx.destination); o.start(at); o.stop(at + dur)
  },
  play(kind) {
    if (!this.on || !this.ctx) return
    const t = this.ctx.currentTime
    if (kind === "place") this.tone(880, t, 0.06, "sine", 0.05)
    if (kind === "hop") this.tone(300, t, 0.14, "square", 0.04, 640)
    if (kind === "chime") { this.tone(660, t, 0.18, "triangle", 0.07); this.tone(880, t + 0.16, 0.25, "triangle", 0.07) }
    if (kind === "bell") { this.tone(1320, t, 0.7, "sine", 0.06); this.tone(1980, t, 0.4, "sine", 0.02) }
  },
}
soundEl.addEventListener("click", () => sound.toggle())

// --- offline -----------------------------------------------------------------
// Going offline drops the cable subscription and nothing else. Edits keep
// landing in the local doc and in the provider's outbox, which replays them
// when the subscription comes back; the reconnect handshake brings in what
// everyone else did meanwhile. Presence is cleared on the way out (peers see
// us leave) and set again before reconnecting, so it goes out with the
// handshake. Cells that arrive from the other side in the seconds after a
// reconnect flash, so the merge can be seen.
let offline = false
let waiting = 0
let reconnectedAt = 0
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
  reconnectedAt = now()
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
  requestFrame()
}
attributionEl.addEventListener("click", () => toggleAttribution())

// --- the roster, the status, the HUD -------------------------------------------
function renderPresence() {
  presenceEl.replaceChildren(...[...awareness.getStates().values()].filter((s) => s?.user).map((s) => {
    const chip = document.createElement("span")
    chip.className = "chip"
    chip.style.background = s.user.color
    chip.textContent = s.user.name + (s.user.name === user.name && !s.planner && !s.life ? " (you)" : "") + (s.status ? ` · ${s.status}` : "")
    return chip
  }))
  if (inviteEl) { inviteEl.disabled = !!plannerState(); inviteEl.textContent = plannerState() ? "The planner is here" : "Invite the planner" }
  if (lifeEl) { lifeEl.disabled = !!lifeState(); lifeEl.textContent = lifeState() ? "The town is awake" : "Wake the town" }
}
function renderStatus() {
  statusEl.classList.toggle("offline", offline)
  badgeEl.hidden = !offline
  if (offline) {
    badgeEl.textContent = `OFFLINE · ${waiting} change${waiting === 1 ? "" : "s"} queued`
    statusEl.textContent = `offline as ${user.name} · ${waiting} change${waiting === 1 ? "" : "s"} waiting to sync`
    return
  }
  const status = provider.status
  statusEl.textContent = status === "synced" ? `synced as ${user.name} · ${tiles.size} tiles` : `${status} as ${user.name}…`
}
let hudTimer = null
let lastSaid = ""
function renderHud() {
  hudTimer ??= setTimeout(() => {
    hudTimer = null
    let roads = 0
    for (const [k, who] of authors.entries()) if (who === "a:planner" && ROADS.has(parseTile(tiles.get(k))?.name)) roads++
    $("hud-people").textContent = String(people().length)
    $("hud-tiles").textContent = String(tiles.size)
    $("hud-roads").textContent = String(roads)
    const p = plannerState()
    if (p?.status) lastSaid = p.status
    $("hud-said").textContent = lastSaid || "…"
  }, 250)
}

// The invites are fetches, not navigations. Under Falcon the answer is a
// stream that stays open while the agent runs, and this page holds it:
// leaving the page closes it, and the agent goes with it. Under Puma the
// answer is an empty 204 and the agent runs on its own.
for (const el of [inviteEl, lifeEl]) {
  el?.closest("form")?.addEventListener("submit", async (e) => {
    e.preventDefault()
    const response = await fetch(e.target.action, { method: "POST", headers: { Accept: "text/event-stream" } })
    const reader = response.body?.getReader()
    while (reader && !(await reader.read()).done) { /* hold the stream until the agent leaves */ }
  })
}

// --- timelapse ---------------------------------------------------------------
// The audit endpoint lists every update the server recorded for this
// document, in order. They are applied one by one to a scratch Y.Doc, with a
// frame kept along the way, and the scrubber picks which frame the map
// shows. Closing the panel returns to the live map.
const timelapse = $("timelapse")
const scrub = $("timelapse-scrub")
const play = $("timelapse-play")
const caption = $("timelapse-caption")
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
  view = makeView((k) => f.tiles.get(k), () => f.tiles.entries())
  drawAll(view)
  requestFrame(true)
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
$("timelapse-refresh").addEventListener("click", loadTimelapse)
timelapse.addEventListener("toggle", () => {
  if (timelapse.open) loadTimelapse()
  else { stopTimelapse(); replaying = false; view = live; live.rebuild(); drawAll(); requestFrame(true) }
})

// --- a crowd, for measuring ----------------------------------------------------
// Fifty pretend visitors, applied to this page's awareness only (with the
// session as origin, so the provider does not send them on), walking a
// step every half second. For frame-time numbers, not for the demo.
let crowd = null
function simulate(n = 50) {
  if (crowd) { clearInterval(crowd.timer); crowd = null; if (n === 0) return }
  const members = Array.from({ length: n }, (_, i) => {
    const a = new Awareness(new Y.Doc())
    a.setLocalState({ user: { name: `Visitor ${i + 1}`, color: COLORS[i % COLORS.length] }, sprite: SPRITES[i % 4], pos: { x: 20 + (i * 7) % 56, y: 20 + (i * 11) % 56 } })
    return a
  })
  const push = () => { for (const a of members) { const s = a.getLocalState(); a.setLocalState({ ...s, pos: { x: clamp(s.pos.x + Math.floor(Math.random() * 3) - 1, 0, W - 1), y: clamp(s.pos.y + Math.floor(Math.random() * 3) - 1, 0, H - 1) } }); applyAwarenessUpdate(awareness, encodeAwarenessUpdate(a, [a.clientID]), provider.session) } }
  push()
  crowd = { timer: setInterval(push, 500), members }
}

// --- wiring ------------------------------------------------------------------
// Everything on screen comes from the document and the presence.
tiles.observe((event) => {
  if (!replaying) {
    live.rebuild()
    const remote = event.transaction.origin === provider.session
    for (const k of event.keysChanged) {
      const c = parse(k)
      if (c) markDirty(c[0], c[1])
      if (remote && reconnectedAt && now() - reconnectedAt < 4000) { flashes.set(k, now()); flashed++ }
    }
    if (offline && !remote) waiting += event.keysChanged.size
    labels = null
  }
  renderStatus(); renderHud()
})
signs.observe((event) => {
  labels = null
  for (const k of event.keysChanged) if (event.transaction.origin === provider.session && authors.get(k) === "a:mayor" && signs.get(k)) sound.play("bell")
  requestFrame()
})
readings.observe(() => { labels = null; requestFrame() })
authors.observe(() => { if (attribution) requestFrame(); renderHud() })
claims.observe(() => requestFrame())
meta.observe(() => { terrain = makeTerrain(meta.get("seed")); drawAll(); requestFrame(true) })
let plannerBusy = null
awareness.on("change", () => {
  const l = lifeState()
  if (l) {
    if (!life || l.clock !== life.clock) clockBase = { clock: l.clock ?? 0.35, at: now() }
    life = l
  } else if (life) { life = null }
  const p = plannerState()
  const busy = p?.status && /laying|building/.test(p.status)
  if (plannerBusy && !busy && p) sound.play("chime")
  plannerBusy = !!busy
  renderPresence(); renderHud(); requestFrame()
})
sheet.addEventListener("load", () => { sheetReady = true; drawAll(); centerOn(pos.x, pos.y); requestFrame(true) })
window.addEventListener("resize", fit)
fit()

provider.onStatusChange(() => {
  renderStatus()
  if (provider.status === "synced") {
    if (!meta.has("seed")) meta.set("seed", Math.floor(Math.random() * 2147483647))
    live.rebuild(); drawAll(); requestFrame(true)
  }
})
setTool(tool)
renderPresence()
renderStatus()
renderHud()
window.__yrb = {
  provider, ydoc, tiles, signs, authors, claims, readings, meta, user, paint, placeSign, moveTo, setTool, goOffline, reconnect, toggleAttribution,
  say, hop, simulate, sound, follow,
  setClock(c) { clockBase = { clock: c, at: now() }; tintDrawn.dirty = true; requestFrame() }, // this page only, for a look at the night
  redraw() { const t0 = now(); drawAll(); requestFrame(true); return now() - t0 }, // ms to repaint the whole town
  get pos() { return pos },
  get terrain() { return terrain },
  get life() { return life },
  get flashed() { return flashed },
  get flashing() { return flashes.size },
  get waving() { return [...waves.values()].filter((until) => until > now()).length },
  get labels() { if (!labels) computeLabels(); return labels },
  camera: { get x() { return cam.x }, get y() { return cam.y }, get zoom() { return cam.zoom }, panBy, zoomAt, centerOn, visible },
  stats: () => ({ frames: stats.frames, avg: stats.frames ? stats.total / stats.frames : 0, max: stats.max, recentAvg: stats.recent.reduce((a, b) => a + b, 0) / (stats.recent.length || 1) }),
}
provider.connect()
