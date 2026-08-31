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

const synced = (s) => js(s, `!!(window.__yrby && window.__yrby.provider.synced)`)
const openBoth = async (path) => {
  for (const s of SESSIONS) await ab(s, "open", `${BASE}${path}`)
  for (const s of SESSIONS) await waitFor(`${s} synced on ${path}`, async () => (await synced(s)) === true)
}

// --- 1) Rich text: typing in one window lands in the other -------------------
await openBoth(`/demos/tiptap/${ROOM}`)

const prose = (s) => js(s, `JSON.stringify(window.__yrby.editor ? window.__yrby.editor.getText() : null)`)
await waitFor("both editors mounted", async () =>
  (await Promise.all(SESSIONS.map(prose))).every((v) => v !== undefined && v !== "null"))

// The editor sits below the fold under this page's header, and a click lands on
// a viewport point — so scroll it in first or the click misses and the keystrokes
// go to the body. `press` is a top-level agent-browser command and cannot be
// chained.
const focusEditor = async (s) => {
  await ab(s, "scrollintoview", ".ProseMirror")
  await ab(s, "click", ".ProseMirror")
}

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

// --- 2) The room is the boundary ---------------------------------------------
// A second room on the same demo is a different document, on the same process.
await ab(B, "open", `${BASE}/demos/tiptap/${ROOM}-other`)
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
await ab(A, "click", "#add-row")
check("the added row reaches both browsers",
  !!(await converge("row add", rowIds, (v) => JSON.parse(v).length === seeded + 1)))
const ROW = seeded

// A types a value while B bolds the same cell. Different keys of the cell's
// Y.Map, so both survive — a scalar cell would have lost one. `press` is a
// top-level agent-browser command and cannot be chained.
await ab(A, "click", await cellInput(A, ROW, "item"))
await ab(A, "keyboard", "type", "VALUE-A")
await ab(A, "press", "Enter")
await ab(B, "click", await cellInput(B, ROW, "item"))
await ab(B, "click", "#toolbar #bold")
check("A's value and B's bold both survive, on both browsers",
  !!(await converge("value + bold", (s) => cell(s, ROW, "item"),
    (v) => JSON.parse(v)[0] === "VALUE-A" && JSON.parse(v)[1] === "700")))

// --- 4) Kanban: a Y.Array, over the same channel ------------------------------
await openBoth(`/demos/kanban/${ROOM}`)

const cardText = (s) => js(s, `JSON.stringify(window.__yrby.cards.toArray().map((c) => c.get("text")).sort())`)
check("both boards hold the seeded cards",
  !!(await converge("seeded cards", cardText, (v) => JSON.parse(v).length === 3)))

await ab(A, "click", '.col input[aria-label="add to To Do"]')
await ab(A, "keyboard", "type", "card from A")
await ab(A, "press", "Enter")
check("a card added in one window reaches the other",
  !!(await converge("added card", cardText, (v) => v.includes("card from A"))))

await ab(A, "close", "--all")
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: site demos — rich text, room isolation, cell-level merges, kanban")
