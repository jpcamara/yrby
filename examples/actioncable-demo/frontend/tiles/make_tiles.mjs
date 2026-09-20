// Builds the city page's tile sheet, public/city/tiles.png, and the index
// that names each frame, src/city_tiles.json. The ground, the trees, the
// roads, and the sign come from Kenney's Tiny Town (CC0, see SOURCES.md);
// the rest is drawn here, in the same palette, as rows of characters.
//
//   bun tiles/make_tiles.mjs
import { PNG } from "pngjs"
import { readFileSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const SIZE = 16
const kenney = PNG.sync.read(readFileSync(resolve(here, "kenney_tiny_town.png")))
const KENNEY_COLUMNS = 12

// Tiny Town's colors, plus water, which the pack does not have.
const PALETTE = {
  o: "#3f2631", // outline
  g: "#84c669", G: "#65a556", // grass, grass shade
  d: "#eaa56c", D: "#cf8254", // dirt, dirt shade
  w: "#bd6c4a", W: "#763b36", // wood, wood shade
  s: "#8b9bb4", S: "#5a6988", t: "#c0cbdc", // stone, stone shade, stone light
  r: "#c34b35", R: "#f28462", // red roof, red roof light
  b: "#5a6988", B: "#8b9bb4", // blue roof, blue roof light
  y: "#fdbe53", Y: "#e38628", // yellow, orange
  a: "#4f8fba", A: "#73bed3", n: "#3b6f96", // water, water light, water shade
  k: "#fcbc8f", // skin
  e: "#ffffff", // white
  ".": null,
}

// A 16x16 sprite from 16 rows of 16 characters. `swap` renames colors, so
// one drawing gives the house its three roofs and the people their shirts.
function sprite(rows, swap = {}) {
  if (rows.length !== SIZE || rows.some((row) => row.length !== SIZE)) throw new Error("a sprite is 16 rows of 16")
  const px = new Uint8Array(SIZE * SIZE * 4)
  rows.forEach((row, y) => [...row].forEach((ch, x) => {
    const hex = PALETTE[swap[ch] ?? ch]
    if (hex === undefined) throw new Error(`no color for ${ch}`)
    if (hex === null) return
    px.set([parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16), 255], (y * SIZE + x) * 4)
  }))
  return px
}

// One 16x16 tile out of the Kenney sheet, by its index in the pack's
// Tilesheet.txt order (12 across).
function fromKenney(index) {
  const px = new Uint8Array(SIZE * SIZE * 4)
  const x0 = (index % KENNEY_COLUMNS) * SIZE
  const y0 = Math.floor(index / KENNEY_COLUMNS) * SIZE
  for (let y = 0; y < SIZE; y++) {
    const from = ((y0 + y) * kenney.width + x0) * 4
    px.set(kenney.data.subarray(from, from + SIZE * 4), y * SIZE * 4)
  }
  return px
}

// A quarter turn clockwise.
function rotate(px) {
  const out = new Uint8Array(px.length)
  for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
    out.set(px.subarray((y * SIZE + x) * 4, (y * SIZE + x) * 4 + 4), ((x * SIZE) + (SIZE - 1 - y)) * 4)
  }
  return out
}

// `under` drawn first, `over` on top where it is opaque.
function stack(under, over) {
  const out = new Uint8Array(under)
  for (let i = 0; i < out.length; i += 4) if (over[i + 3]) out.set(over.subarray(i, i + 4), i)
  return out
}

// Every pixel's alpha scaled, for the claim marker.
function fade(px, alpha) {
  const out = new Uint8Array(px)
  for (let i = 3; i < out.length; i += 4) out[i] = Math.round(out[i] * alpha)
  return out
}

const HOUSE = [
  "................",
  ".......oo.......",
  "......orRo......",
  ".....orrRRo.....",
  "....orrrRRRo....",
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

const SHOP = [
  "................",
  ".oooooooooooooo.",
  ".oeeeeeeeeeeeeo.",
  ".oooooooooooooo.",
  ".oreoreoreoreoo.",
  ".oooooooooooooo.",
  "..ossssssssssso.",
  "..oAAAAAAsoWWo..",
  "..oAeAAAAsoWWo..",
  "..oAAAAAAsoWyo..",
  "..oAAAAAAsoWWo..",
  "..ossssssssWWo..",
  "..oooooooooooo..",
  "................",
  "................",
  "................",
]

const WATER = [
  "aaaaaaaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aaAAAaaaaaaaaaaa",
  "aaaaaaaaaaaAAaaa",
  "aaaaaaaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aaaaaannaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aAAAaaaaaaaaaaaa",
  "aaaaaaaaaaaAAAaa",
  "aaaaaaaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
  "aaaannaaaaaaaaaa",
  "aaaaaaaaaaaaaaaa",
]

// A bridge for a road that runs left to right: rails along the top and
// bottom, planks between.
const BRIDGE = [
  "oooooooooooooooo",
  "wWwWwWwWwWwWwWwW",
  "oooooooooooooooo",
  "wwwWwwwWwwwWwwwW",
  "wwwWwwwWwwwWwwwW",
  "wwwWwwwWwwwWwwwW",
  "WWWWWWWWWWWWWWWW",
  "wwwWwwwWwwwWwwwW",
  "wwwWwwwWwwwWwwwW",
  "wwwWwwwWwwwWwwwW",
  "WWWWWWWWWWWWWWWW",
  "wwwWwwwWwwwWwwwW",
  "wwwWwwwWwwwWwwwW",
  "oooooooooooooooo",
  "wWwWwWwWwWwWwWwW",
  "oooooooooooooooo",
]

// The grass edge of a road, drawn over the road on each side that has no
// road beside it.
const ROAD_EDGE = [
  "gggggggggggggggg",
  "gggggggggggggggg",
  "DDDDDDDDDDDDDDDD",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
  "................",
]

// Where the planner means to build.
const MARKER = [
  "yy..yy..yy..yy..",
  "y..............y",
  "................",
  "................",
  "y..............y",
  "y..............y",
  "................",
  "................",
  "y..............y",
  "y..............y",
  "................",
  "................",
  "y..............y",
  "y..............y",
  "................",
  "..yy..yy..yy..yy",
]

// A person: hair `h`, a shirt `c`, and trousers `p`; the swap picks them.
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

const grass = fromKenney(0)
const roadEdge = sprite(ROAD_EDGE)
const bridge = sprite(BRIDGE)
const water = sprite(WATER)
const sign = fromKenney(83)

// The sheet, in this order. Ground tiles are opaque; the rest are drawn
// over grass here so the page draws one frame per cell.
const FRAMES = [
  ["grass", grass],
  ["grass_flowers", fromKenney(1)],
  ["grass_sparkle", fromKenney(2)],
  ["road", fromKenney(25)],
  ["road_edge_up", roadEdge],
  ["road_edge_right", rotate(roadEdge)],
  ["road_edge_down", rotate(rotate(roadEdge))],
  ["road_edge_left", rotate(rotate(rotate(roadEdge)))],
  ["water", water],
  ["bridge_h", stack(water, bridge)],
  ["bridge_v", stack(water, rotate(bridge))],
  ["house_red", stack(grass, sprite(HOUSE))],
  ["house_blue", stack(grass, sprite(HOUSE, { r: "b", R: "B" }))],
  ["house_orange", stack(grass, sprite(HOUSE, { r: "Y", R: "y" }))],
  ["shop", stack(grass, sprite(SHOP))],
  ["park", stack(fromKenney(1), fromKenney(28))],
  ["sign", stack(grass, sign)],
  ["marker", fade(sprite(MARKER), 0.85)],
  ["person_red", sprite(PERSON, { h: "W", c: "r", p: "S" })],
  ["person_blue", sprite(PERSON, { h: "y", c: "b", p: "W" })],
  ["person_green", sprite(PERSON, { h: "o", c: "G", p: "S" })],
  ["person_yellow", sprite(PERSON, { h: "Y", c: "y", p: "b" })],
  ["planner", sprite(PLANNER)],
]

const sheet = new PNG({ width: SIZE * FRAMES.length, height: SIZE })
FRAMES.forEach(([, px], i) => {
  for (let y = 0; y < SIZE; y++) sheet.data.set(px.subarray(y * SIZE * 4, (y + 1) * SIZE * 4), (y * sheet.width + i * SIZE) * 4)
})
writeFileSync(resolve(here, "../../public/city/tiles.png"), PNG.sync.write(sheet))
const index = { size: SIZE, frames: Object.fromEntries(FRAMES.map(([name], i) => [name, i])) }
writeFileSync(resolve(here, "../src/city_tiles.json"), `${JSON.stringify(index, null, 2)}\n`)
console.log(`${FRAMES.length} frames -> public/city/tiles.png, src/city_tiles.json`)
