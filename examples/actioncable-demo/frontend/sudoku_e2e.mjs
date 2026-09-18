// Two real browsers on the sudoku page, and the checker between them. Both
// see the same puzzle; a digit typed in one shows in the other; a clash is
// flagged in both by the checker, which shows up as a player; a hint asked
// for in one fills a cell in both. Asserts on the shared Yjs maps at
// window.__yrb, and takes a screenshot of each browser at the end.
//
//   PORT=9600 STORE_KIND=file bin/rails s -p 9600        # server
//   node frontend/sudoku_e2e.mjs                         # invites the checker from the page
//   CHECKER=process ROOM=x node frontend/sudoku_e2e.mjs  # a checker already running: bin/sudoku-peer x
import { execFileSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const BASE = process.env.BASE || `http://127.0.0.1:${process.env.PORT || 9600}`
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const ROOM = process.env.ROOM || `sudoku-${`${Date.now()}`.slice(-6)}`
const INVITE = (process.env.CHECKER || "invite") === "invite"
const SHOTS = process.env.SHOTS || "/tmp"
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ab = (s, ...a) => { try { return execFileSync(AB, a, { env: { ...process.env, AGENT_BROWSER_SESSION: s }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) } catch (e) { return `${e.stdout || ""}${e.stderr || ""}` } }
async function waitEval(s, js, label, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (/\btrue\b/.test(ab(s, "eval", js))) return true; await sleep(300) } console.log(`  TIMEOUT: ${label} (${s}): ${ab(s, "eval", js).trim()}`); return false }
let failures = 0; const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }
const synced = (s) => waitEval(s, "!!window.__yrb?.provider?.synced", "synced")
const checkerHere = (s) => waitEval(s, "[...window.__yrb.provider.awareness.getStates().values()].some(x => x?.checker)", "checker present", 20000)
// eval prints strings quoted; take the words out.
const words = (out) => out.match(/[a-z0-9]+/g) || []
// The empty cells in row order, so a hint's cell is known.
const empties = (s) => words(ab(s, "eval", `[...document.querySelectorAll('.cell')].filter(el => !el.classList.contains('given')).map(el => el.dataset.cell).join(' ')`))
// A given, its digit, and an empty cell in its row, to make a clash.
const clash = (s) => words(ab(s, "eval", `(() => { const g = window.__yrb.givens; for (const [k, d] of g.entries()) { const r = k.slice(1, 2); for (let c = 0; c < 9; c++) { const cell = 'r' + r + 'c' + c; if (!g.has(cell) && !window.__yrb.grid.has(cell)) return [k, d, cell].join(' ') } } })()`))

console.log(`# sudoku (${ROOM}, checker: ${INVITE ? "invited from the page" : "already running"})`)
// a first, and b once a has the puzzle: the first open makes it, and two
// first opens on different workers would each make one.
ab("su-a", "open", `${BASE}/docs/${ROOM}/sudoku`)
check("a synced", await synced("su-a"))
ab("su-b", "open", `${BASE}/docs/${ROOM}/sudoku`)
check("b synced", await synced("su-b"))
check("both see the same 34 givens", await waitEval("su-b", "window.__yrb.givens.size === 34", "givens") && /\b34\b/.test(ab("su-a", "eval", "window.__yrb.givens.size")))

if (INVITE) ab("su-a", "click", ".invite-checker")
check("the checker shows up as a player in a", await checkerHere("su-a"))
check("the checker shows up as a player in b", await checkerHere("su-b"))
check("the checker reported progress", await waitEval("su-b", "window.__yrb.progress.get('filled') === 34", "progress"))

const [first, second] = empties("su-a")
ab("su-a", "click", `[data-cell=${first}]`); ab("su-a", "press", "1") // press: a keydown on the focused cell
check("b sees a's digit", await waitEval("su-b", `window.__yrb.grid.get('${first}') === 1`, "digit"))
check("b sees a on that cell", await waitEval("su-b", `document.querySelector('[data-cell=${first}]').classList.contains('here')`, "presence"))
ab("su-a", "press", "Backspace")
check("b sees a clear it", await waitEval("su-b", `!window.__yrb.grid.has('${first}')`, "clear"))

const [given, digit, cell] = clash("su-b")
ab("su-b", "click", `[data-cell=${cell}]`); ab("su-b", "press", String(digit))
check(`the checker flags ${cell} and ${given} in a`, await waitEval("su-a", `window.__yrb.conflicts.has('${cell}') && window.__yrb.conflicts.has('${given}')`, "conflict a"))
check("and in b, drawn red", await waitEval("su-b", `document.querySelector('[data-cell=${cell}]').classList.contains('conflict')`, "conflict b"))
check("progress counts the clash", await waitEval("su-a", "window.__yrb.progress.get('conflicts') === 2", "progress conflicts"))
check("the checker's presence is on a clashing cell", await waitEval("su-a", `[...window.__yrb.provider.awareness.getStates().values()].some(x => x?.checker && ['${cell}', '${given}'].includes(x.cell))`, "checker cell"))
ab("su-b", "screenshot", "--full", `${SHOTS}/sudoku-b-clash.png`)

ab("su-a", "click", "#hint")
check("the request is written into the document", await waitEval("su-b", "window.__yrb.requests.has('hint') || window.__yrb.grid.size >= 2", "request"))
check("the checker fills the first empty cell in b", await waitEval("su-b", `window.__yrb.grid.get('${first === cell ? second : first}') >= 1`, "hint"))
check("and takes the request out", await waitEval("su-a", "!window.__yrb.requests.has('hint')", "request cleared"))
check("the filled cell does not clash", await waitEval("su-a", `!window.__yrb.conflicts.has('${first === cell ? second : first}')`, "hint valid"))

ab("su-b", "press", "Backspace")
check("clearing the clash clears the flags in a", await waitEval("su-a", "window.__yrb.conflicts.size === 0", "flags cleared"))

ab("su-a", "screenshot", "--full", `${SHOTS}/sudoku-a.png`); ab("su-b", "screenshot", "--full", `${SHOTS}/sudoku-b.png`)
console.log(`screenshots: ${SHOTS}/sudoku-b-clash.png ${SHOTS}/sudoku-a.png ${SHOTS}/sudoku-b.png`)
ab("su-a", "close"); ab("su-b", "close")

console.log(""); if (failures) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: sudoku e2e (${ROOM})`); process.exit(0)
