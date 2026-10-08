// Opens two real Chrome windows on this site's demo rooms and checks that the
// pages sync through the server and its SQLite store.
//
//   PORT=3888 node site_e2e.mjs
//
// Needs agent-browser (local install or AB_BIN) and a Chromium it can drive.
// Most checks compare the two browsers with each other and also check for the
// typed text, so two pages that agree on the wrong content still fail.
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { dirname, resolve } from "node:path"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

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

// Polls until both browsers report the same value and it passes `ok`, then
// returns that value. The assertions run on the state the poll saw, because a
// second read could happen mid-render.
async function converge(label, read, ok, ms = 30000) {
  const end = Date.now() + ms
  let last = []
  while (Date.now() < end) {
    const pair = await Promise.all(SESSIONS.map(read))
    last = pair
    if (pair[0] !== undefined && pair[0] === pair[1] && ok(pair[0])) return pair[0]
    await sleep(400)
  }
  check(`TIMEOUT: ${label}: A=${last[0]} B=${last[1]}`, false)
  return undefined
}

// A click goes to a point in the viewport. These pages have a header, a room
// bar, and an explanation above the click target, so in a short window the
// target is below the fold and the click misses without an error. The
// keystrokes then go to the body. So always scroll the target into view first.
const clickAt = async (session, selector) => {
  await ab(session, "scrollintoview", selector)
  return ab(session, "click", selector)
}

// A fixed, short viewport. A CI runner's default window is smaller than a
// laptop's, and that difference decides whether a click hits its target, so
// the test sets the size itself.
const VIEWPORT = ["1280", "720"]

const synced = (s) => js(s, `!!(window.__yrby && window.__yrby.provider.synced)`)
const openBoth = async (path) => {
  for (const s of SESSIONS) {
    await ab(s, "open", `${BASE}${path}`)
    await ab(s, "set", "viewport", ...VIEWPORT)
  }
  for (const s of SESSIONS) await waitFor(`${s} synced on ${path}`, async () => (await synced(s)) === true)
}

// --- 0) Rich text (Lexxy): two browsers through NoteChannel -----------------
// This part runs the published lexxy-realtime stack end to end: the
// <yrby-document> wrapper with a room token as its grant, NoteChannel on top of
// LexxyRealtime::DocumentChannel, the record-based document, and the server
// rendering the document into the note's plain body column with Y::Lexxy. No
// other demo renders on the server.
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

// The stored HTML column. Poll the GET endpoint until the server-rendered
// note.body includes what was typed. Y::Lexxy produced this HTML in Ruby, and
// no browser serialized it.
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

// Presence went over `send`, the guarded server path, and not as an AnyCable
// whisper. This public demo hides whisper from the provider (see room.js), so
// awareness takes the same throttled, validated path as document updates and
// doesn't skip the Rails guard by going client to client. The two chips above
// show that presence works over send.
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

// Add a blank row to type into. Clicking an input puts the caret wherever the
// click hits, so the typing checks use cells that start empty.
const seeded = JSON.parse(await rowIds(A)).length
await clickAt(A, "#add-row")
check("the added row reaches both browsers",
  !!(await converge("row add", rowIds, (v) => JSON.parse(v).length === seeded + 1)))
const ROW = seeded

// A types a value while B bolds the same cell. They change different keys of
// the cell's Y.Map, so both survive. With a scalar cell, one would be lost.
// `press` is a top-level agent-browser command and cannot be chained.
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

await clickAt(A, '.col input[aria-label="Add a card to To Do"]')
await ab(A, "keyboard", "type", "card from A")
await ab(A, "press", "Enter")
check("a card added in one window reaches the other",
  !!(await converge("added card", cardText, (v) => v.includes("card from A"))))

await ab(A, "close", "--all")
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: site demos: lexxy and its stored column, tiptap, room isolation, cell-level merges, kanban")
