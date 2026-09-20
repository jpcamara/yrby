// Builds the city page's sprite sheet, public/city/tiles.png, and the atlas
// that names each frame's rectangle in it, src/city_tiles.json. The grass,
// the trees, the dirt path, the stone plaza, the cottages, the bench, the
// sign, and a few props come from Kenney's Tiny Town (CC0, see
// SOURCES.md); the rest is drawn here, in the same palette: the roads, the
// water, the red bridge, the cable car track, the Victorian houses, the
// shop, the people, the cars, the gulls, and the boats.
//
//   bun tiles/make_tiles.mjs
import { PNG } from "pngjs"
import { readFileSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const T = 16
const kenney = PNG.sync.read(readFileSync(resolve(here, "kenney_tiny_town.png")))
const KENNEY_COLUMNS = 12

// Tiny Town's colors, plus water, asphalt, and the painted ladies' paint.
const PALETTE = {
  o: "#3f2631", // outline
  g: "#84c669", G: "#65a556", // grass, grass shade
  d: "#eaa56c", D: "#cf8254", // dirt, dirt shade
  w: "#bd6c4a", W: "#763b36", // wood, wood shade
  s: "#8b9bb4", S: "#5a6988", t: "#c0cbdc", // stone, stone shade, stone light
  r: "#c34b35", R: "#f28462", // red, red light
  b: "#5a6988", B: "#8b9bb4", // blue roof, blue roof light
  y: "#fdbe53", Y: "#e38628", // yellow, orange
  a: "#4f8fba", A: "#73bed3", n: "#3b6f96", // water, water light, water shade
  k: "#fcbc8f", // skin
  e: "#ffffff", // white
  p: "#5c6274", P: "#6a7186", // asphalt, asphalt light
  c: "#e3b95a", // lane paint
  m: "#3a3f4d", // tyre
  ".": null,
}

const hex = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16), 255]
const color = (c) => {
  const h = c.startsWith("#") ? c : PALETTE[c]
  if (h === undefined) throw new Error(`no color for ${c}`)
  return h === null ? null : hex(h)
}

// --- a tiny raster kit --------------------------------------------------------
const buffer = (w, h) => ({ w, h, px: new Uint8Array(w * h * 4) })
function put(buf, x, y, rgba) {
  if (x < 0 || y < 0 || x >= buf.w || y >= buf.h || !rgba) return
  buf.px.set(rgba, (y * buf.w + x) * 4)
}
const at = (buf, x, y) => buf.px.subarray((y * buf.w + x) * 4, (y * buf.w + x) * 4 + 4)
function rect(buf, x, y, w, h, c) {
  const rgba = color(c)
  for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) put(buf, i, j, rgba)
}
function frameRect(buf, x, y, w, h, c) {
  rect(buf, x, y, w, 1, c); rect(buf, x, y + h - 1, w, 1, c); rect(buf, x, y, 1, h, c); rect(buf, x + w - 1, y, 1, h, c)
}
// `over` on `under`, offset, where over is opaque.
function blit(under, over, dx = 0, dy = 0) {
  for (let y = 0; y < over.h; y++) for (let x = 0; x < over.w; x++) {
    const p = at(over, x, y)
    if (p[3]) put(under, x + dx, y + dy, p)
  }
  return under
}
function crop(buf, x, y, w, h) {
  const out = buffer(w, h)
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) put(out, i, j, at(buf, x + i, y + j))
  return out
}
// A quarter turn clockwise.
function rotate(buf) {
  const out = buffer(buf.h, buf.w)
  for (let y = 0; y < buf.h; y++) for (let x = 0; x < buf.w; x++) put(out, buf.h - 1 - y, x, at(buf, x, y))
  return out
}
function flipH(buf) {
  const out = buffer(buf.w, buf.h)
  for (let y = 0; y < buf.h; y++) for (let x = 0; x < buf.w; x++) put(out, buf.w - 1 - x, y, at(buf, x, y))
  return out
}
function fade(buf, alpha) {
  const out = { w: buf.w, h: buf.h, px: new Uint8Array(buf.px) }
  for (let i = 3; i < out.px.length; i += 4) out.px[i] = Math.round(out.px[i] * alpha)
  return out
}
// Every channel scaled, for the hill bands of grass.
function tint(buf, [r, g, b]) {
  const out = { w: buf.w, h: buf.h, px: new Uint8Array(buf.px) }
  for (let i = 0; i < out.px.length; i += 4) {
    if (!out.px[i + 3]) continue
    out.px[i] = Math.min(255, Math.round(out.px[i] * r))
    out.px[i + 1] = Math.min(255, Math.round(out.px[i + 1] * g))
    out.px[i + 2] = Math.min(255, Math.round(out.px[i + 2] * b))
  }
  return out
}
// A small deterministic hash for texture: the same sheet every build.
const noise = (x, y, s) => { let h = Math.imul(x, 374761393) + Math.imul(y, 668265263) + Math.imul(s, 1442695041); h = Math.imul(h ^ (h >>> 13), 1274126177); h ^= h >>> 16; return (h >>> 0) / 4294967296 }

// A sprite from rows of characters, any size. `swap` renames colors, so
// one drawing gives the people their shirts and the cars their paint.
function sprite(rows, swap = {}) {
  const w = rows[0].length
  if (rows.some((row) => row.length !== w)) throw new Error("ragged sprite")
  const buf = buffer(w, rows.length)
  rows.forEach((row, y) => [...row].forEach((ch, x) => put(buf, x, y, color(swap[ch] ?? ch))))
  return buf
}

// One 16x16 tile out of the Kenney sheet, by its index in the pack's
// Tilesheet.txt order (12 across).
function fromKenney(index) {
  return crop({ w: kenney.width, h: kenney.height, px: kenney.data }, (index % KENNEY_COLUMNS) * T, Math.floor(index / KENNEY_COLUMNS) * T, T, T)
}

// --- ground --------------------------------------------------------------------
// Grass in four hill bands, from Kenney's three grass tiles: lower and
// bluer by the bay, yellower up the hill.
const BANDS = [[0.9, 0.96, 1.02], [1, 1, 1], [1.06, 1.03, 0.9], [1.12, 1.07, 0.78]]
const grassFrames = BANDS.flatMap((mul, band) => [0, 1, 2].map((v) => [`grass_${band}_${v}`, tint(fromKenney(v), mul)]))

// The lip of a terrace: on a cell higher than its neighbour, a dark rim on
// the side that faces down (south, east) and a light one where the hill
// continues up (north, west).
function ledge(side) {
  const buf = buffer(T, T)
  if (side === "s") { rect(buf, 0, 13, T, 1, "G"); rect(buf, 0, 14, T, 1, "#4d7d40"); rect(buf, 0, 15, T, 1, "#3d6534") }
  if (side === "e") { rect(buf, 13, 0, 1, T, "G"); rect(buf, 14, 0, 1, T, "#4d7d40"); rect(buf, 15, 0, 1, T, "#3d6534") }
  if (side === "n") rect(buf, 0, 0, T, 1, "#a8dc8c")
  if (side === "w") rect(buf, 0, 0, 1, T, "#a8dc8c")
  return buf
}

// Water in sixteen shore shapes and two frames. The mask says which sides
// have land: N=1, E=2, S=4, W=8. A shore is a sand line and a foam line;
// the wave highlights move between the frames.
function water(mask, f) {
  const buf = buffer(T, T)
  rect(buf, 0, 0, T, T, "a")
  for (let y = 0; y < T; y++) for (let x = 0; x < T; x++) {
    const v = noise(x, y, 7 + f)
    if (v < 0.035) { put(buf, x, y, color("A")); put(buf, x + 1, y, color("A")); put(buf, x + 2, y, color("A")) }
    else if (v > 0.975) put(buf, x, y, color("n"))
  }
  const sand = "#e8d59f", foam = f ? "#a9d9e6" : "A"
  const dash = (i) => (i + f * 2) % 4 < 3
  if (mask & 1) { rect(buf, 0, 0, T, 1, sand); for (let x = 0; x < T; x++) if (dash(x)) put(buf, x, 1, color(foam)) }
  if (mask & 4) { rect(buf, 0, 15, T, 1, sand); for (let x = 0; x < T; x++) if (dash(x)) put(buf, x, 14, color(foam)) }
  if (mask & 8) { rect(buf, 0, 0, 1, T, sand); for (let y = 0; y < T; y++) if (dash(y)) put(buf, 1, y, color(foam)) }
  if (mask & 2) { rect(buf, 15, 0, 1, T, sand); for (let y = 0; y < T; y++) if (dash(y)) put(buf, 14, y, color(foam)) }
  return buf
}

// Asphalt in sixteen shapes. The mask says which sides join another road:
// N=1, E=2, S=4, W=8. A side that joins nothing gets a kerb and a
// pavement; where two joined sides meet there is a pavement corner; a
// straight has a lane line.
function road(mask) {
  const buf = buffer(T, T)
  for (let y = 0; y < T; y++) for (let x = 0; x < T; x++) put(buf, x, y, color(noise(x, y, 3) < 0.12 ? "P" : "p"))
  const [n, e, s, w] = [mask & 1, mask & 2, mask & 4, mask & 8]
  const pave = (x, y, pw, ph) => rect(buf, x, y, pw, ph, "t")
  if (!n) { pave(0, 0, T, 2); rect(buf, 0, 2, T, 1, "s") }
  if (!s) { pave(0, 14, T, 2); rect(buf, 0, 13, T, 1, "s") }
  if (!w) { pave(0, 0, 2, T); rect(buf, 2, 0, 1, T, "s") }
  if (!e) { pave(14, 0, 2, T); rect(buf, 13, 0, 1, T, "s") }
  const corner = (x, y) => { pave(x, y, 3, 3); frameRect(buf, x, y, 3, 3, "s"); pave(x + (x ? 1 : 0), y + (y ? 1 : 0), 2, 2) }
  if (n && e) corner(13, 0)
  if (e && s) corner(13, 13)
  if (s && w) corner(0, 13)
  if (w && n) corner(0, 0)
  if (mask === 5) for (let y = 0; y < T; y++) if (y % 6 < 3) rect(buf, 7, y, 1, 1, "c")
  if (mask === 10) for (let x = 0; x < T; x++) if (x % 6 < 3) rect(buf, x, 7, 1, 1, "c")
  return buf
}

// Cable car rails, laid over a road: two rails and the slot between them.
function rails() {
  const buf = buffer(T, T)
  rect(buf, 0, 4, T, 1, "s"); rect(buf, 0, 5, T, 1, "S")
  rect(buf, 0, 10, T, 1, "s"); rect(buf, 0, 11, T, 1, "S")
  rect(buf, 0, 7, T, 1, "o")
  return buf
}

// The red bridge: a deck with rails, over the water, and every few cells a
// tower. Drawn for a span that runs left to right; turned for the other.
function bridge(tower) {
  const buf = buffer(T, T)
  for (let y = 3; y < 13; y++) for (let x = 0; x < T; x++) put(buf, x, y, color(noise(x, y, 5) < 0.12 ? "P" : "p"))
  rect(buf, 0, 2, T, 1, "o"); rect(buf, 0, 3, T, 1, "r"); rect(buf, 0, 13, T, 1, "o"); rect(buf, 0, 12, T, 1, "r")
  for (let x = 1; x < T; x += 4) { rect(buf, x, 0, 1, 3, "R"); rect(buf, x, 13, 1, 3, "R") }
  rect(buf, 0, 0, T, 1, "r"); rect(buf, 0, 15, T, 1, "r")
  for (let x = 0; x < T; x++) if (x % 6 < 3) rect(buf, x, 7, 1, 1, "c")
  if (tower) {
    for (const x of [2, 11]) { rect(buf, x, 0, 3, T, "r"); rect(buf, x, 0, 1, T, "R"); rect(buf, x + 2, 0, 1, T, "W") }
    rect(buf, 2, 5, 12, 2, "r"); rect(buf, 2, 5, 12, 1, "R")
  }
  return buf
}

// A dirt path and a stone plaza, autotiled from Kenney's nine-slice sets:
// each quarter of the cell comes from the slice its two outer sides call
// for. The mask says which sides join the same kind: N=1, E=2, S=4, W=8.
function nineSlice(indexes, mask) {
  const tiles = Object.fromEntries(Object.entries(indexes).map(([k, i]) => [k, fromKenney(i)]))
  const [n, e, s, w] = [!!(mask & 1), !!(mask & 2), !!(mask & 4), !!(mask & 8)]
  const pick = (joinedV, joinedH, top, left) => {
    if (!joinedV && !joinedH) return tiles[top ? (left ? "tl" : "tr") : (left ? "bl" : "br")]
    if (!joinedV) return tiles[top ? "t" : "b"]
    if (!joinedH) return tiles[left ? "l" : "r"]
    return tiles.m
  }
  const buf = buffer(T, T)
  const quad = (tile, x, y) => blit(buf, crop(tile, x, y, 8, 8), x, y)
  quad(pick(n, w, true, true), 0, 0); quad(pick(n, e, true, false), 8, 0)
  quad(pick(s, w, false, true), 0, 8); quad(pick(s, e, false, false), 8, 8)
  return buf
}
const DIRT = { tl: 12, t: 13, tr: 14, l: 24, m: 25, r: 26, bl: 36, b: 37, br: 38 }
const STONE = { tl: 96, t: 97, tr: 98, l: 108, m: 109, r: 110, bl: 120, b: 121, br: 122 }

// --- props ---------------------------------------------------------------------
// A fence joins its neighbours: a post in the middle, rails toward each
// side that has fence.
function fence(mask) {
  const buf = buffer(T, T)
  const [n, e, s, w] = [mask & 1, mask & 2, mask & 4, mask & 8]
  if (w) { rect(buf, 0, 6, 8, 2, "w"); rect(buf, 0, 10, 8, 2, "w"); rect(buf, 0, 7, 8, 1, "W"); rect(buf, 0, 11, 8, 1, "W") }
  if (e) { rect(buf, 8, 6, 8, 2, "w"); rect(buf, 8, 10, 8, 2, "w"); rect(buf, 8, 7, 8, 1, "W"); rect(buf, 8, 11, 8, 1, "W") }
  if (n) { rect(buf, 6, 0, 3, 8, "w"); rect(buf, 8, 0, 1, 8, "W") }
  if (s) { rect(buf, 6, 8, 3, 8, "w"); rect(buf, 8, 8, 1, 8, "W") }
  rect(buf, 6, 3, 3, 11, "w"); rect(buf, 8, 3, 1, 11, "W"); rect(buf, 6, 2, 3, 1, "o"); rect(buf, 6, 14, 3, 1, "o")
  return buf
}

const LAMP = [
  "................",
  "......oooo......",
  ".....oyyyyo.....",
  ".....oyeeyo.....",
  ".....oyyyyo.....",
  "......oooo......",
  ".......oo.......",
  ".......SS.......",
  ".......SS.......",
  ".......SS.......",
  ".......SS.......",
  ".......SS.......",
  ".......SS.......",
  "......oSSo......",
  ".....oSSSSo.....",
  "......oooo......",
]

const FLOWERS = [
  "................",
  "................",
  "................",
  "................",
  "....R......e....",
  "...RyR....eye...",
  "....R..y...e....",
  "....G.yey..G....",
  ".......y..G.....",
  ".G..R...G.......",
  "...RyR.......e..",
  "....R.......eye.",
  "..y..G.......e..",
  ".yey....R.......",
  "..y....RyR......",
  "........R.......",
]

const HYDRANT = [
  "................",
  "................",
  "................",
  "................",
  "................",
  "......oooo......",
  ".....oRRRRo.....",
  "......orro......",
  "....ooorroo.....",
  "....oRRrrRRo....",
  "....ooorroo.....",
  "......orro......",
  "......orro......",
  ".....orrrro.....",
  ".....oooooo.....",
  "................",
]

// Where the planner means to build.
const CONE = [
  "................",
  "................",
  "................",
  "......oo........",
  ".....oYYo.......",
  ".....oYYo.......",
  "....oYYYYo......",
  "....oeeeeo......",
  "....oYYYYo......",
  "...oYYYYYYo.....",
  "...oeeeeeeo.....",
  "...oYYYYYYo.....",
  "..oYYYYYYYYo....",
  ".oooooooooooo...",
  ".oSSSSSSSSSSo...",
  ".oooooooooooo...",
]

// --- buildings -----------------------------------------------------------------
// The small houses, one cell each, with a chimney for the smoke.
const HOUSE = [
  "................",
  ".......oo..oo...",
  "......orRo.SSo..",
  ".....orrRRoSSo..",
  "....orrrRRRSSo..",
  "...orrrrRRRRo...",
  "..orrrrrRRRRRo..",
  ".orrrrrrRRRRRRo.",
  ".oooooooooooooo.",
  "..owwwwwwwwwwo..",
  "..ottowwwwoWWo..",
  "..ottowwwwoWWo..",
  "..owwwwwwwoWyo..",
  "..owwwwwwwoWWo..",
  "..oooooooooooo..",
  "................",
]

// A painted lady: two cells wide and two tall, a gable over a two-storey
// bay window, a door up a few steps, and a chimney. `paint` picks the
// walls, the trim, and the roof.
function victorian({ wall, light, trim, roof, roofLight }) {
  const buf = buffer(32, 32)
  rect(buf, 3, 12, 26, 18, wall); frameRect(buf, 3, 12, 26, 18, "o")
  rect(buf, 4, 19, 24, 1, trim) // the band between the floors
  rect(buf, 4, 13, 1, 16, light); rect(buf, 27, 13, 1, 16, light) // corner boards
  // the roof: a gable over the whole front, shingles in rows
  for (let y = 3; y <= 12; y++) {
    const hw = Math.round((y - 3) * 1.5) + 1
    rect(buf, 15 - hw, y, hw * 2 + 2, 1, y % 3 === 0 ? roofLight : roof)
    put(buf, 15 - hw, y, color("o")); put(buf, 16 + hw, y, color("o"))
  }
  rect(buf, 1, 12, 30, 1, "o"); rect(buf, 2, 13, 28, 1, trim) // the eave
  rect(buf, 15, 2, 2, 1, "o")
  rect(buf, 13, 7, 6, 5, "o"); rect(buf, 14, 8, 4, 3, "A"); put(buf, 14, 8, color("e")) // the gable window
  rect(buf, 24, 1, 4, 7, "S"); rect(buf, 24, 1, 4, 1, "s"); rect(buf, 23, 0, 6, 1, "o"); rect(buf, 23, 1, 1, 7, "o"); rect(buf, 28, 1, 1, 7, "o") // the chimney
  rect(buf, 5, 14, 9, 14, light); frameRect(buf, 5, 14, 9, 14, "o") // the bay window, two storeys
  for (const wy of [15, 21]) {
    rect(buf, 6, wy, 7, 5, trim)
    rect(buf, 7, wy + 1, 2, 3, "A"); rect(buf, 10, wy + 1, 2, 3, "A")
    put(buf, 7, wy + 1, color("e")); put(buf, 10, wy + 1, color("e"))
    rect(buf, 6, wy + 5, 7, 1, "o")
  }
  rect(buf, 19, 14, 6, 6, trim); rect(buf, 20, 15, 4, 4, "A"); put(buf, 20, 15, color("e")); rect(buf, 19, 19, 6, 1, "o") // upstairs
  rect(buf, 19, 21, 7, 8, trim); rect(buf, 20, 22, 5, 7, "W"); rect(buf, 21, 23, 3, 2, "A"); put(buf, 24, 26, color("y")) // the door
  rect(buf, 18, 29, 9, 1, "s"); rect(buf, 17, 30, 11, 1, "t"); rect(buf, 17, 31, 11, 1, "S") // the stoop
  rect(buf, 3, 30, 14, 1, "o"); rect(buf, 28, 30, 1, 1, "o")
  return buf
}

const PAINT = {
  teal: { wall: "#4f9a94", light: "#7cc4bd", trim: "e", roof: "S", roofLight: "s" },
  lilac: { wall: "#9b7bb8", light: "#c5a8dd", trim: "e", roof: "W", roofLight: "w" },
  cream: { wall: "#f2e2b8", light: "#fff5dc", trim: "#4f9a94", roof: "r", roofLight: "R" },
}

// The grand house: two cells wide and three tall, a turret on the left
// with a pointed roof, three floors of windows, and two chimneys.
function grand() {
  const buf = buffer(32, 48)
  const wall = "#6f8fbf", light = "#9bb4d6", trim = "e"
  rect(buf, 11, 14, 19, 32, wall); frameRect(buf, 11, 14, 19, 32, "o")
  rect(buf, 12, 24, 17, 1, trim); rect(buf, 12, 35, 17, 1, trim)
  rect(buf, 9, 8, 22, 6, "S"); rect(buf, 9, 8, 22, 1, "s"); rect(buf, 9, 11, 22, 1, "s"); frameRect(buf, 9, 8, 22, 7, "o") // the mansard
  rect(buf, 12, 6, 16, 2, "S"); rect(buf, 11, 5, 18, 1, "o"); rect(buf, 12, 6, 16, 1, "s")
  for (const cx of [15, 24]) { rect(buf, cx, 1, 3, 5, "S"); rect(buf, cx, 1, 3, 1, "s"); frameRect(buf, cx - 1, 0, 5, 6, "o") } // chimneys
  rect(buf, 3, 12, 8, 34, light); rect(buf, 3, 12, 1, 34, "o"); rect(buf, 10, 12, 1, 34, wall) // the turret
  for (let y = 2; y <= 12; y++) {
    const hw = Math.round((y - 2) * 0.45)
    rect(buf, 6 - hw, y, hw * 2 + 2, 1, y % 2 ? "r" : "R"); put(buf, 6 - hw, y, color("o")); put(buf, 7 + hw, y, color("o"))
  }
  rect(buf, 2, 12, 10, 1, "o"); put(buf, 6, 1, color("o")); put(buf, 7, 1, color("o"))
  for (const wy of [16, 27, 38]) { rect(buf, 5, wy, 4, 6, trim); rect(buf, 6, wy + 1, 2, 4, "A"); put(buf, 6, wy + 1, color("e")) }
  for (const wy of [16, 27]) for (const wx of [14, 21]) { rect(buf, wx, wy, 6, 6, trim); rect(buf, wx + 1, wy + 1, 4, 4, "A"); put(buf, wx + 1, wy + 1, color("e")); rect(buf, wx, wy + 5, 6, 1, "o") }
  rect(buf, 14, 38, 6, 6, trim); rect(buf, 15, 39, 4, 4, "A"); put(buf, 15, 39, color("e"))
  rect(buf, 21, 37, 7, 8, trim); rect(buf, 22, 38, 5, 7, "W"); rect(buf, 23, 39, 3, 2, "A"); put(buf, 26, 42, color("y")) // the door
  rect(buf, 20, 45, 9, 1, "s"); rect(buf, 19, 46, 11, 1, "t"); rect(buf, 19, 47, 11, 1, "S")
  rect(buf, 3, 46, 16, 1, "o"); rect(buf, 30, 46, 1, 1, "o")
  return buf
}

// The shop: a flat roof with a parapet, a sign board, a striped awning
// over a big window, and a door.
function shop([stripe, stripeLight]) {
  const buf = buffer(32, 32)
  rect(buf, 2, 8, 28, 22, "s"); frameRect(buf, 2, 8, 28, 22, "o")
  for (let y = 9; y < 30; y += 3) for (let x = 3 + (y % 2) * 2; x < 29; x += 5) rect(buf, x, y, 3, 1, "S") // brick
  rect(buf, 1, 4, 30, 4, "S"); rect(buf, 1, 4, 30, 1, "t"); frameRect(buf, 1, 4, 30, 5, "o") // the parapet
  rect(buf, 4, 9, 24, 5, "#f2e2b8"); frameRect(buf, 4, 9, 24, 5, "W") // the sign board
  for (const [x, c] of [[7, "r"], [11, "a"], [15, "Y"], [19, "G"], [23, "r"]]) rect(buf, x, 11, 2, 1, c)
  for (let x = 2; x < 30; x++) rect(buf, x, 14, 1, 4, Math.floor(x / 3) % 2 ? stripe : stripeLight) // the awning
  rect(buf, 2, 18, 28, 1, "o"); for (let x = 2; x < 30; x += 3) put(buf, x, 18, color(stripe))
  rect(buf, 4, 19, 16, 10, "A"); frameRect(buf, 4, 19, 16, 10, "o"); rect(buf, 12, 19, 1, 10, "o"); rect(buf, 5, 20, 3, 1, "e") // the window
  rect(buf, 22, 20, 6, 10, "W"); frameRect(buf, 22, 20, 6, 10, "o"); rect(buf, 23, 21, 4, 3, "A"); put(buf, 26, 26, color("y")) // the door
  rect(buf, 2, 30, 28, 1, "o"); rect(buf, 3, 31, 27, 1, "S")
  return buf
}
const AWNINGS = { shop: ["r", "e"], shop_blue: ["a", "e"], shop_green: ["G", "e"] }

// Cottages out of Kenney's roof and wall sets: two cells wide, two tall.
function cottage(roofL, roofR, wallL, wallR) {
  const buf = buffer(32, 32)
  blit(buf, fromKenney(roofL), 0, 0); blit(buf, fromKenney(roofR), 16, 0)
  blit(buf, fromKenney(wallL), 0, 16); blit(buf, fromKenney(wallR), 16, 16)
  return buf
}

// --- people, cars, and the rest --------------------------------------------
// A person: hair `h`, a shirt `c`, and trousers `p`; the swap picks them.
// Three frames: standing, and two steps of a walk.
const PERSON = [
  "................",
  "................",
  ".....oooooo.....",
  "....ohhhhhho....",
  "....ohhhhhho....",
  "....okkkkkko....",
  "....okokkoko....",
  "....okkkkkko....",
  ".....okkkko.....",
  "....occccccoo...",
  "...ockccccckko..",
  "...okoccccco.o..",
  ".....oppppo.....",
  ".....opoopo.....",
  ".....oooooo.....",
  "................",
]
const walking = (rows, step) => rows.map((row, y) => {
  if (y === 12) return step ? "....oppppppo...." : "....opppppo....."
  if (y === 13) return step ? ".....op..opo...." : "....opo..po....."
  if (y === 14) return step ? ".....oo..oo....." : "....oo...oo....."
  return row
})

// The planner: a hard hat over the same person.
const PLANNER = [
  "................",
  "....oooooooo....",
  "...oyyyyyyyyo...",
  "...oyyyyyyyyo...",
  "..oooooooooooo..",
  "....okkkkkko....",
  "....okokkoko....",
  "....okkkkkko....",
  ".....okkkko.....",
  "....oYYYYYYoo...",
  "...okYYYYYYkko..",
  "...okoYYYYYo.o..",
  ".....oSSSSo.....",
  ".....oSooSo.....",
  ".....oooooo.....",
  "................",
]

// A car, driving to the right; `C` is its paint.
const CAR = [
  "................",
  "................",
  "................",
  "................",
  "................",
  ".....oooooo.....",
  "....oCAAAACCo...",
  "...oCCAAAACCCo..",
  ".oooCCCCCCCCCCo.",
  ".oCCCCCCCCCCCCo.",
  ".oCCCCCCCCCCCCo.",
  ".oooooooooooooo.",
  "..ommo....ommo..",
  "...oo......oo...",
  "................",
  "................",
]

const TRAM = [
  "................",
  "................",
  ".......o........",
  ".......o........",
  "..oooooooooooo..",
  ".oeeeeeeeeeeeeo.",
  ".orAAorAAorAAro.",
  ".orAAorAAorAAro.",
  ".orrrrrrrrrrrro.",
  ".orrrrrrrrrrrro.",
  ".oeeeeeeeeeeeeo.",
  ".oooooooooooooo.",
  "..ommo....ommo..",
  "...oo......oo...",
  "................",
  "................",
]

const GULL = [
  [
    "................", "................", "................", "................", "................", "................",
    "....e......e....", "...ee.oo...ee...", "....eeeeeeee....", ".....eeeeee.....",
    "................", "................", "................", "................", "................", "................",
  ],
  [
    "................", "................", "................", "................", "................", "................",
    "................", "......oo........", ".....eeeeeee....", "...eeeeeeeeee...", "..ee........ee..",
    "................", "................", "................", "................", "................",
  ],
]

const BOAT = [
  "................",
  "........o.......",
  "........oe......",
  "........oee.....",
  "........oeee....",
  "........oeeee...",
  "........oeeeee..",
  "........oeeeeee.",
  "........o.......",
  ".ooooooooooooo..",
  "..owwwwwwwwwwo..",
  "...oWWWWWWWWo...",
  "....oooooooo....",
  "................",
  "................",
  "................",
]

const WAVE = [
  "................",
  "................",
  "................",
  ".....o..o.......",
  "....oko.ko.o....",
  "....okookook....",
  "..o.okkkkkkko...",
  ".oko.okkkkkko...",
  "..okookkkkkko...",
  "...okkkkkkkko...",
  "....okkkkkkko...",
  ".....okkkkko....",
  ".....okkkkko....",
  "......oooooo....",
  "................",
  "................",
]

const PEDESTRIANS = [
  { h: "W", c: "r", p: "S" }, { h: "y", c: "b", p: "W" }, { h: "o", c: "G", p: "S" }, { h: "Y", c: "y", p: "b" },
  { h: "W", c: "A", p: "W" }, { h: "o", c: "e", p: "S" }, { h: "y", c: "R", p: "W" }, { h: "o", c: "Y", p: "S" },
]
const PEOPLE = { red: { h: "W", c: "r", p: "S" }, blue: { h: "y", c: "b", p: "W" }, green: { h: "o", c: "G", p: "S" }, yellow: { h: "Y", c: "y", p: "b" } }
const CARS = { red: "r", blue: "a", white: "e", yellow: "y" }

// --- the sheet -----------------------------------------------------------------
const frames = []
const add = (name, buf) => frames.push([name, buf])
for (const [name, buf] of grassFrames) add(name, buf)
for (const side of ["n", "e", "s", "w"]) add(`ledge_${side}`, ledge(side))
for (let mask = 0; mask < 16; mask++) {
  add(`water_${mask}_0`, water(mask, 0)); add(`water_${mask}_1`, water(mask, 1))
  add(`road_${mask}`, road(mask))
  add(`path_${mask}`, nineSlice(DIRT, mask)); add(`plaza_${mask}`, nineSlice(STONE, mask))
  add(`fence_${mask}`, fence(mask))
}
add("rails_h", rails()); add("rails_v", rotate(rails()))
add("bridge_h", bridge(false)); add("bridge_h_tower", bridge(true))
add("bridge_v", rotate(bridge(false))); add("bridge_v_tower", rotate(bridge(true)))
add("cobble", fromKenney(43))
add("sign", fromKenney(83))
add("bench", blit(blit(buffer(T, T), crop(fromKenney(80), 0, 0, 8, 16)), crop(fromKenney(82), 8, 0, 8, 16), 8, 0))
add("lamp", sprite(LAMP)); add("flowers", sprite(FLOWERS)); add("hydrant", sprite(HYDRANT)); add("cone", sprite(CONE))
add("shrub", fromKenney(17)); add("mushrooms", fromKenney(29)); add("tree_small", fromKenney(28)); add("tree_orange_small", fromKenney(27))
add("park", blit(blit(buffer(16, 32), fromKenney(5), 0, 0), fromKenney(16), 0, 16))
add("pine", blit(blit(buffer(16, 32), fromKenney(4), 0, 0), fromKenney(16), 0, 16))
add("tree_orange", blit(blit(buffer(16, 32), fromKenney(3), 0, 0), fromKenney(15), 0, 16))
add("house_red", sprite(HOUSE)); add("house_blue", sprite(HOUSE, { r: "b", R: "B" })); add("house_orange", sprite(HOUSE, { r: "Y", R: "y" }))
for (const [name, paint] of Object.entries(PAINT)) add(`victorian_${name}`, victorian(paint))
add("grand", grand())
for (const [name, awning] of Object.entries(AWNINGS)) add(name, shop(awning))
add("cottage", cottage(52, 54, 84, 85)); add("stone_cottage", cottage(48, 50, 88, 89))
for (const [i, swap] of PEDESTRIANS.entries()) [0, 1, 2].forEach((f) => add(`ped_${i}_${f}`, sprite(f ? walking(PERSON, f === 2) : PERSON, swap)))
for (const [name, swap] of Object.entries(PEOPLE)) [0, 1, 2].forEach((f) => add(`person_${name}_${f}`, sprite(f ? walking(PERSON, f === 2) : PERSON, swap)))
;[0, 1, 2].forEach((f) => add(`planner_${f}`, sprite(f ? walking(PLANNER, f === 2) : PLANNER)))
for (const [name, c] of Object.entries(CARS)) { add(`car_h_${name}`, sprite(CAR, { C: c })); add(`car_v_${name}`, rotate(sprite(CAR, { C: c }))) }
add("tram_h", sprite(TRAM)); add("tram_v", rotate(sprite(TRAM)))
add("gull_0", sprite(GULL[0])); add("gull_1", sprite(GULL[1]))
add("boat", sprite(BOAT)); add("boat_flip", flipH(sprite(BOAT)))
add("wave", sprite(WAVE))
add("marker", fade(sprite(CONE), 0.9))

// Shelf packing, tallest frames first, into a sheet 512 wide.
const WIDTH = 512
frames.sort((a, b) => b[1].h - a[1].h || b[1].w - a[1].w)
const atlas = {}
let shelfY = 0, shelfH = 0, cursor = 0
for (const [name, buf] of frames) {
  if (cursor + buf.w > WIDTH) { shelfY += shelfH; shelfH = 0; cursor = 0 }
  if (buf.h > shelfH) shelfH = buf.h
  atlas[name] = [cursor, shelfY, buf.w, buf.h]
  cursor += buf.w
}
const HEIGHT = shelfY + shelfH
const sheet = new PNG({ width: WIDTH, height: HEIGHT })
for (const [name, buf] of frames) {
  const [x0, y0] = atlas[name]
  for (let y = 0; y < buf.h; y++) sheet.data.set(buf.px.subarray(y * buf.w * 4, (y + 1) * buf.w * 4), ((y0 + y) * WIDTH + x0) * 4)
}
writeFileSync(resolve(here, "../../public/city/tiles.png"), PNG.sync.write(sheet))
const index = { size: T, width: WIDTH, height: HEIGHT, frames: Object.fromEntries(Object.keys(atlas).sort().map((k) => [k, atlas[k]])) }
writeFileSync(resolve(here, "../src/city_tiles.json"), `${JSON.stringify(index)}\n`)
console.log(`${frames.length} frames, ${WIDTH}x${HEIGHT} -> public/city/tiles.png, src/city_tiles.json`)
