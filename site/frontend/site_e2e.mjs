// Two real Chrome windows on this site's demo rooms, proving the pages actually
// sync against the in-memory store.
//
//   PORT=3888 node site_e2e.mjs
//
// Needs agent-browser (local install or AB_BIN) and a Chromium it can drive.
// The two browsers are compared against each other rather than against expected
// strings, so a converged-but-wrong page still fails.
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { dirname, resolve } from "node:path"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { inflateSync } from "node:zlib"

const pexec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const LOCAL_AB = resolve(here, "node_modules/.bin/agent-browser")
const AB = process.env.AB_BIN || (existsSync(LOCAL_AB) ? LOCAL_AB : "agent-browser")
const BASE = `http://127.0.0.1:${process.env.PORT || 3888}`
const ROOM = process.env.ROOM || `e2e-${Date.now()}`
const SESSIONS = ["siteA", "siteB"]
const [A, B] = SESSIONS

let failures = 0
const check = (label, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${label}`); if (!ok) failures++ }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const ab = (session, ...args) =>
  pexec(AB, args, { env: { ...process.env, AGENT_BROWSER_SESSION: session }, encoding: "utf8" })
    .then((r) => r.stdout.trim())
    .catch((e) => `${e.stdout || ""}${e.stderr || ""}`)

// agent-browser `eval` prints the value JSON-serialized; parse it back, or
// return undefined on an evaluation error.
async function js(session, expr) {
  const out = await ab(session, "eval", expr)
  if (out.startsWith("✗")) return undefined
  try { return JSON.parse(out) } catch { return out }
}

async function waitFor(label, fn, ms = 30000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await fn()) return true; await sleep(400) }
  check(`TIMEOUT: ${label}`, false)
  return false
}

// Poll until both browsers report the same thing AND it satisfies `ok`, then
// hand that agreed value back — so the assertions run on the state the poll
// actually saw, not on a re-read that can land mid-render.
async function converge(label, read, ok, ms = 30000) {
  const end = Date.now() + ms
  let last = []
  while (Date.now() < end) {
    const pair = await Promise.all(SESSIONS.map(read))
    last = pair
    if (pair[0] !== undefined && pair[0] === pair[1] && ok(pair[0])) return pair[0]
    await sleep(400)
  }
  check(`TIMEOUT: ${label} — A=${last[0]} B=${last[1]}`, false)
  return undefined
}

// A click lands on a viewport point, and these pages carry a header, a room bar,
// and an explanation above the thing being clicked — so on a short window the
// target is below the fold and the click misses silently (the keystrokes then go
// to the body). Scroll first, always.
const clickAt = async (session, selector) => {
  await ab(session, "scrollintoview", selector)
  return ab(session, "click", selector)
}

// Fixed, and deliberately short. A CI runner's default window is smaller than a
// laptop's, and that difference is exactly what decides whether a click lands —
// so pin it rather than inherit it.
const VIEWPORT = ["1280", "720"]

const synced = (s) => js(s, `!!(window.__yrby && window.__yrby.provider.synced)`)
const openBoth = async (path) => {
  for (const s of SESSIONS) {
    await ab(s, "open", `${BASE}${path}`)
    await ab(s, "set", "viewport", ...VIEWPORT)
  }
  for (const s of SESSIONS) await waitFor(`${s} synced on ${path}`, async () => (await synced(s)) === true)
}

// --- 0) Rich text (Lexxy, the flagship): two browsers through NoteChannel ----
// This leg exercises the published lexxy-realtime stack end to end: sgid auth,
// the record-based document, and — the part no other demo has — the server
// rendering the document into the note's plain body column via Y::Lexxy.
await openBoth(`/demos/lexxy/${ROOM}`)

const lexxyText = (s) => js(s, `JSON.stringify(document.querySelector("lexxy-editor [contenteditable]")?.innerText ?? null)`)
await waitFor("both lexxy editors mounted", async () =>
  (await Promise.all(SESSIONS.map(lexxyText))).every((v) => v !== undefined && v !== "null"))

await clickAt(A, "lexxy-editor [contenteditable]")
await ab(A, "keyboard", "type", "lexxy from A")
check("A's lexxy typing reaches B",
  !!(await converge("lexxy prose", lexxyText, (v) => v.includes("lexxy from A"))))

await clickAt(B, "lexxy-editor [contenteditable]")
await ab(B, "press", "End")
await ab(B, "keyboard", "type", " and B")
check("both lexxy editors converge on both people's text",
  !!(await converge("lexxy both", lexxyText, (v) => v.includes("lexxy from A") && v.includes("and B"))))

const lexxyChips = (s) => js(s, `document.querySelectorAll("#presence .chip").length`)
await waitFor("lexxy presence lists two people", async () => (await lexxyChips(B)) === 2)
check("B sees two people in the lexxy room", (await lexxyChips(B)) === 2)

// The materialized column: poll the GET endpoint until the server-rendered
// note.body catches up with what was typed. This HTML came from Y::Lexxy in
// Ruby — no browser serialized it.
const storedBody = async () => {
  const res = await fetch(`${BASE}/demos/lexxy/${ROOM}/body`)
  return (await res.json()).body || ""
}
await waitFor("note.body materializes server-side", async () =>
  (await storedBody()).includes("lexxy from A") && (await storedBody()).includes("and B"))
const body = await storedBody()
check(`the stored column is server-rendered HTML (${body.slice(0, 40)}…)`,
  body.startsWith("<p>") && body.includes("lexxy from A"))

// --- 1) Rich text (Tiptap): same shape through DocumentChannel ---------------
await openBoth(`/demos/tiptap/${ROOM}`)

const prose = (s) => js(s, `JSON.stringify(window.__yrby.editor ? window.__yrby.editor.getText() : null)`)
await waitFor("both editors mounted", async () =>
  (await Promise.all(SESSIONS.map(prose))).every((v) => v !== undefined && v !== "null"))

// `press` is a top-level agent-browser command and cannot be chained.
const focusEditor = (s) => clickAt(s, ".ProseMirror")

await focusEditor(A)
await ab(A, "keyboard", "type", "hello from A")
check("A's typing reaches B", !!(await converge("prose", prose, (v) => v.includes("hello from A"))))

// B types too, from its own caret: both texts survive in both windows.
await focusEditor(B)
await ab(B, "press", "End")
await ab(B, "keyboard", "type", " and B")
check("both windows converge on both people's text",
  !!(await converge("prose both", prose, (v) => v.includes("hello from A") && v.includes("and B"))))

// Presence: A's name chip shows up in B's window.
const chips = (s) => js(s, `JSON.stringify([...document.querySelectorAll("#presence .chip")].map((e) => e.textContent).sort())`)
await waitFor("presence lists two people", async () => JSON.parse((await chips(B)) || "[]").length === 2)
check("B sees two people in the room", JSON.parse(await chips(B)).length === 2)

// ...and it got there over `send`, the guarded server path — NOT an AnyCable
// whisper. This public demo hides whisper from the provider (see room.js), so
// awareness rides the same throttled, validated path as document updates rather
// than relaying client-to-client past the Rails guard. Presence still reaching
// two chips (above) is the end-to-end proof it works over send.
const transport = (s) => js(s, `JSON.stringify(window.__yrbyTransport)`)
const counts = JSON.parse(await transport(A))
check("whisper is not offered to the provider on the public demo", counts.canWhisper === false)
check(`awareness went out via send, not a whisper (${counts.awarenessSends} awareness sends)`, counts.awarenessSends > 0)
check(`document updates went through send too (${counts.documentSends} document sends)`, counts.documentSends > 0)

// --- 2) The room is the boundary ---------------------------------------------
// A second room on the same demo is a different document, on the same process.
await ab(B, "open", `${BASE}/demos/tiptap/${ROOM}-other`)
await ab(B, "set", "viewport", ...VIEWPORT)
await waitFor("B synced in the other room", async () => (await synced(B)) === true)
await waitFor("B's editor mounted in the other room", async () => (await prose(B)) !== "null")
check("a different room is a different document", !((await prose(B)) || "").includes("hello from A"))

// --- 3) Spreadsheet: cell-level merges ---------------------------------------
await openBoth(`/demos/spreadsheet/${ROOM}`)

const rowIds = (s) => js(s, `JSON.stringify(window.__yrby.rows.toArray().map((r) => r.get("id")))`)
const cell = (s, row, col) => js(s, `(() => {
  const td = document.querySelector('td[data-cell="' + window.__yrby.rows.get(${row}).get("id") + ':${col}"]')
  return td ? JSON.stringify([td.firstChild.value, td.firstChild.style.fontWeight]) : "missing"
})()`)
const cellInput = (s, row, col) =>
  js(s, `'td[data-cell="' + window.__yrby.rows.get(${row}).get("id") + ':${col}"] input'`)

check("both browsers hold the same seeded rows",
  !!(await converge("seeded rows", rowIds, (v) => JSON.parse(v).length === 3)))

// A blank row to type into: clicking an input drops the caret wherever the click
// lands, so the typed cases use cells that start empty.
const seeded = JSON.parse(await rowIds(A)).length
await clickAt(A, "#add-row")
check("the added row reaches both browsers",
  !!(await converge("row add", rowIds, (v) => JSON.parse(v).length === seeded + 1)))
const ROW = seeded

// A types a value while B bolds the same cell. Different keys of the cell's
// Y.Map, so both survive — a scalar cell would have lost one. `press` is a
// top-level agent-browser command and cannot be chained.
await clickAt(A, await cellInput(A, ROW, "item"))
await ab(A, "keyboard", "type", "VALUE-A")
await ab(A, "press", "Enter")
await clickAt(B, await cellInput(B, ROW, "item"))
await clickAt(B, "#toolbar #bold")
check("A's value and B's bold both survive, on both browsers",
  !!(await converge("value + bold", (s) => cell(s, ROW, "item"),
    (v) => JSON.parse(v)[0] === "VALUE-A" && JSON.parse(v)[1] === "700")))

// --- 4) Kanban: a Y.Array, over the same channel ------------------------------
await openBoth(`/demos/kanban/${ROOM}`)

const cardText = (s) => js(s, `JSON.stringify(window.__yrby.cards.toArray().map((c) => c.get("text")).sort())`)
check("both boards hold the seeded cards",
  !!(await converge("seeded cards", cardText, (v) => JSON.parse(v).length === 3)))

await clickAt(A, '.col input[aria-label="add to To Do"]')
await ab(A, "keyboard", "type", "card from A")
await ab(A, "press", "Enter")
check("a card added in one window reaches the other",
  !!(await converge("added card", cardText, (v) => v.includes("card from A"))))

// --- 5) Pixels: a Y.Map of cells, and the canvas rendered again in Ruby -------
await openBoth(`/demos/pixels/${ROOM}`)

const cellsOf = (s) => js(s, `JSON.stringify([...window.__yrby.pixels.entries()].sort())`)
// A clicks the canvas holding one color; B paints a cell from its own window
// holding another. Both maps have to agree on both cells.
await js(A, `window.__yrby.pickColor(5)`)
await clickAt(A, "#pixel-canvas")
await js(B, `window.__yrby.pickColor(12); window.__yrby.paint(3, 4)`)
const cells = await converge("pixel cells", cellsOf, (v) => {
  const m = new Map(JSON.parse(v))
  return m.get("3,4") === 12 && [...m.values()].includes(5)
})
check("A's click and B's paint reach both windows", !!cells)
const clicked = (JSON.parse(cells || "[]").find(([, v]) => v === 5) || [])[0]
check(`A's click landed on a cell (${clicked})`, !!clicked)

// Presence: two chips, and A's pointer as an outlined cell in B's window.
const cursorsIn = (s) => js(s, `document.querySelectorAll("#pixel-cursors .pixel-cursor").length`)
await waitFor("pixel presence lists two people", async () => (await lexxyChips(B)) === 2)
check("B sees two people in the pixel room", (await lexxyChips(B)) === 2)
await ab(A, "hover", "#pixel-canvas")
await waitFor("A's cursor shows in B's window", async () => (await cursorsIn(B)) === 1)
check("B sees A's cursor over the grid", (await cursorsIn(B)) === 1)

// The PNG endpoint: the same map, rendered by Ruby. Decoded here from the
// bytes (header, then the inflated scanlines) so the painted cells are read
// back from the image, not from the page.
const decodePng = (buf) => {
  let offset = 8
  let side = 0
  const idat = []
  while (offset < buf.length) {
    const length = buf.readUInt32BE(offset)
    const type = buf.toString("ascii", offset + 4, offset + 8)
    const data = buf.subarray(offset + 8, offset + 8 + length)
    if (type === "IHDR") side = data.readUInt32BE(0)
    if (type === "IDAT") idat.push(data)
    offset += 12 + length
  }
  const scanlines = inflateSync(Buffer.concat(idat))
  const scale = side / 64
  return { side, indexAt: (x, y) => scanlines[(y * scale * (side + 1)) + 1 + (x * scale)] }
}
const [cx, cy] = String(clicked).split(",").map(Number)
const pngResponse = await fetch(`${BASE}/demos/pixels/${ROOM}/canvas.png`)
const png = decodePng(Buffer.from(await pngResponse.arrayBuffer()))
check("the PNG endpoint answers image/png", (pngResponse.headers.get("content-type") || "").startsWith("image/png"))
check(`the PNG is 512 px square (${png.side})`, png.side === 512)
check("the PNG carries B's cell at palette index 12", png.indexAt(3, 4) === 12)
check("the PNG carries A's clicked cell at palette index 5", png.indexAt(cx, cy) === 5)

// The timelapse: the update log replayed in Ruby, blank at the start and
// matching the live canvas at the end.
const timelapse = await (await fetch(`${BASE}/demos/pixels/${ROOM}/timelapse`)).json()
const frameOf = (frame) => decodePng(Buffer.from(frame.png.replace(/^data:image\/png;base64,/, ""), "base64"))
check(`the timelapse holds the recorded updates (${timelapse.updates})`, timelapse.updates >= 2)
check("the timelapse has a frame per update plus the blank start", timelapse.frames.length === timelapse.updates + 1)
const firstFrame = frameOf(timelapse.frames[0])
const lastFrame = frameOf(timelapse.frames[timelapse.frames.length - 1])
check("the first frame is blank", firstFrame.indexAt(3, 4) === 0 && firstFrame.indexAt(cx, cy) === 0)
check("the last frame matches the live canvas", lastFrame.indexAt(3, 4) === 12 && lastFrame.indexAt(cx, cy) === 5)

await ab(A, "close", "--all")
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: site demos — lexxy + materialized column, tiptap, room isolation, cell-level merges, kanban, pixels + the Ruby PNG and timelapse")
