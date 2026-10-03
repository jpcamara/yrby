// The spreadsheet page through REAL Chrome: two browsers on the same sheet,
// asserting what the nested-cell data model buys. A cell is a Y.Map of
// { value, bold, fill }, so the interesting cases are about conflict
// granularity — different cells, the same property of one cell, and different
// properties of one cell. The two browsers are compared against each other, not
// against expected strings pulled out of a log, so a converged-but-wrong sheet
// still fails.
//
//   PORT=3777 node spreadsheet_e2e.mjs
//
// Needs agent-browser (local install, AB_BIN, or a sibling lexxy-realtime
// checkout) and a Chromium it can drive. A single-process server is enough (the
// async cable adapter relays awareness in-process); a Redis-backed cluster works
// too.
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { dirname, resolve } from "node:path"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

const pexec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const LOCAL_AB = resolve(here, "node_modules/.bin/agent-browser")
const AB =
  process.env.AB_BIN ||
  (existsSync(LOCAL_AB) ? LOCAL_AB : `${process.env.HOME}/Projects/lexxy-realtime/node_modules/.bin/agent-browser`)
const BASE = `http://127.0.0.1:${process.env.PORT || 3777}`
const ROOM = process.env.ROOM || `sheet-${Date.now()}`
const SESSIONS = ["sheetA", "sheetB"]
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
// hand that agreed value back for the assertions — so the checks run on the
// state the poll actually saw, not on a re-read that can land mid-render.
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

// The whole sheet as this browser renders it, in DOCUMENT order (not the
// browser's sort order — the two browsers deliberately sort differently, and
// document order is what has to agree). Read off the DOM inputs and styles, so
// this is what a user sees, not just what the Y.Doc holds.
const rendered = (s) => js(s, `(() => {
  const order = window.__yrb.rows.toArray().map((r) => r.get("id"))
  return JSON.stringify(order.map((rowId) => {
    const tr = document.querySelector('tr[data-row-id="' + rowId + '"]')
    if (!tr) return null
    return [...tr.children]
      .map((td) => [td.dataset.cell.split(":")[1], td.firstChild.value, td.firstChild.style.fontWeight, td.style.backgroundColor])
      .sort((x, y) => x[0].localeCompare(y[0]))
  }))
})()`)
const synced = (s) => js(s, `!!(window.__yrb && window.__yrb.provider.synced)`)
const rowIds = (s) => js(s, `JSON.stringify(window.__yrb.rows.toArray().map((r) => r.get("id")))`)
const rowOrder = (s) => js(s, `JSON.stringify([...document.querySelectorAll("#grid tbody tr")].map((tr) => tr.dataset.rowId))`)
const peerLabels = (s) => js(s, `JSON.stringify([...document.querySelectorAll("#grid .peerlabel")].map((e) => e.textContent))`)

// One cell, addressed by DOCUMENT row index (both browsers agree on that, and
// neither's sort order can move it): [value, font-weight, fill].
const cell = (s, row, col) => js(s, `(() => {
  const td = document.querySelector('td[data-cell="' + window.__yrb.rows.get(${row}).get("id") + ':${col}"]')
  return td ? JSON.stringify([td.firstChild.value, td.firstChild.style.fontWeight, td.style.backgroundColor]) : "missing"
})()`)
const cellInput = (s, row, col) =>
  js(s, `'td[data-cell="' + window.__yrb.rows.get(${row}).get("id") + ':${col}"] input'`)

// 1) Two real browsers on the same sheet, synced, on the seeded rows.
for (const s of SESSIONS) await ab(s, "open", `${BASE}/docs/${ROOM}/spreadsheet`)
for (const s of SESSIONS) await waitFor(`${s} synced`, async () => (await synced(s)) === true)
check("both browsers hold the same seeded rows",
  !!(await converge("seeded rows", rowIds, (v) => JSON.parse(v).length === 3)))

// Clicking an input drops the caret wherever the click lands, so the typed
// cases all use cells that start empty (the blank rows added below) and the
// typed text is the whole value. `press` is a top-level agent-browser command
// and cannot be chained.
async function typeCell(session, row, col, text) {
  await ab(session, "click", await cellInput(session, row, col))
  await ab(session, "keyboard", "type", text)
  await ab(session, "press", "Enter") // commit, the way the page does
}

// 2) The two browsers sort differently. Everything after this happens while
// their view state disagrees — that is the point of keeping sorting out of the
// document.
await ab(A, "click", 'th[data-col="owner"] .sort')
await ab(B, "click", 'th[data-col="qty"] .sort')
await ab(B, "click", 'th[data-col="qty"] .sort') // descending
const [orderA, orderB] = await Promise.all(SESSIONS.map(rowOrder))
check("the two browsers render the rows in different orders", !!orderA && orderA !== orderB)

// 3) Concurrent row adds from both browsers: Y.Array keeps both. The blank rows
// they append are what the typed cases below edit.
const seeded = JSON.parse(await rowIds(A)).length
await Promise.all(SESSIONS.map((s) => ab(s, "click", "#add-row")))
check("concurrent row adds from both browsers both survive",
  !!(await converge("row adds", rowIds, (v) => JSON.parse(v).length === seeded + 2)))
const ROW = seeded // the first of the two blank rows

// 4) Edits to DIFFERENT cells of the same row both land, typed through the real
// inputs and committed with Enter, the way the page works.
await typeCell(A, ROW, "item", "ITEM-A")
await typeCell(B, ROW, "notes", "NOTES-B")
const sheet = await converge("different-cell edits", rendered,
  (v) => v.includes("ITEM-A") && v.includes("NOTES-B"))
check("edits to different cells both land, and both browsers render the same sheet", !!sheet)

// 5) The SAME property of the SAME cell, written concurrently. Partition both
// browsers first so neither has seen the other's write, then reconnect: last
// write wins and both browsers must agree on which.
await Promise.all(SESSIONS.map((s) => js(s, `window.__yrb.provider.disconnect(); "off"`)))
await js(A, `window.__yrb.getCell(window.__yrb.rows.get(${ROW}), "owner").set("value", "OWNER-A"); "set"`)
await js(B, `window.__yrb.getCell(window.__yrb.rows.get(${ROW}), "owner").set("value", "OWNER-B"); "set"`)
await Promise.all(SESSIONS.map((s) => js(s, `window.__yrb.provider.connect(); "on"`)))
const owner = await converge("same-property conflict", (s) => cell(s, ROW, "owner"),
  (v) => ["OWNER-A", "OWNER-B"].includes(JSON.parse(v)[0]))
check(`same property of one cell: one winner, both agree (${owner && JSON.parse(owner)[0]})`, !!owner)
check("the whole sheet is still identical after the conflict",
  !!(await converge("sheet after conflict", rendered, (v) => v.includes("OWNER-"))))

// 6) The case the nesting exists for: A writes `value` while B writes `bold` on
// the SAME cell, neither having seen the other. Different keys of the cell's
// Y.Map, so both survive — a scalar cell would have lost one.
await Promise.all(SESSIONS.map((s) => js(s, `window.__yrb.provider.disconnect(); "off"`)))
await typeCell(A, ROW, "qty", "VALUE-A")
// B bolds the same cell through the toolbar: click the cell to select it, then
// the B button (which preventDefaults mousedown so the selection survives).
await ab(B, "click", await cellInput(B, ROW, "qty"))
await ab(B, "click", "#toolbar #bold")
await Promise.all(SESSIONS.map((s) => js(s, `window.__yrb.provider.connect(); "on"`)))
const item = await converge("value + bold on one cell", (s) => cell(s, ROW, "qty"),
  (v) => JSON.parse(v)[0] === "VALUE-A" && JSON.parse(v)[1] === "700")
check("A's value and B's bold both survive on both browsers, on the same cell", !!item)

// 7) Presence: the cell B is focused in is outlined in B's color and labelled
// with B's name, in A's window — wherever that row sits in A's sort order.
const bName = await js(B, `window.__yrb.user.name`)
await ab(B, "click", await cellInput(B, ROW, "notes"))
await waitFor("A shows B's focused cell", async () => (await peerLabels(A))?.includes(bName))
check(`A renders B's focused-cell label ("${bName}")`, (await peerLabels(A)).includes(bName))
const peerCell = await js(A, `(() => {
  const td = document.querySelector("#grid td.peer")
  return JSON.stringify([td && td.dataset.cell.split(":")[1], !!td && td.style.boxShadow !== ""])
})()`)
check("the outlined cell is the one B is in, with a border", peerCell === JSON.stringify(["notes", true]))
await ab(B, "click", "#add-row") // blur the cell
await waitFor("A drops B's cell marker on blur", async () => (await peerLabels(A)) === "[]")
check("the focused-cell marker clears on blur", (await peerLabels(A)) === "[]")

// 8) None of the view state reached the document: the sheet holds rows and
// cells only, even though the two browsers have been sorted differently
// throughout.
const shared = await js(A, `JSON.stringify({
  roots: [...window.__yrb.ydoc.share.keys()],
  keys: [...new Set(window.__yrb.rows.toArray().flatMap((r) => [...r.keys()]))].sort(),
})`)
check("the shared doc holds only rows and cells, no sorting or column order",
  shared === JSON.stringify({ roots: ["rows"], keys: ["id", "item", "notes", "owner", "qty"] }))
check("the browsers are still sorted differently at the end",
  (await rowOrder(A)) !== (await rowOrder(B)))

await ab(A, "close", "--all")
console.log("")
if (failures > 0) { console.log(`FAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: spreadsheet — cell-level merges, per-browser sorting, focused-cell presence")
