// Two real browsers on the city page, and the planner between them. Both
// paint and see each other's tiles and characters; the planner, invited from
// the page, connects two houses with a road, bridges to a house on an island,
// and plants a park where a sign asks for one; one browser goes offline,
// both keep painting, and everything merges on reconnect; the attribution
// toggle tints the map; the timelapse replays the log. Asserts on the shared
// Yjs maps at window.__yrb, and takes a screenshot at each beat.
//
//   PORT=9600 STORE_KIND=file bin/rails s -p 9600         # server
//   node frontend/city_e2e.mjs                            # invites the planner from the page
//   PLANNER=process ROOM=x node frontend/city_e2e.mjs     # a planner already running: bin/city-planner x
//   FRAMES=/tmp/frames node frontend/city_e2e.mjs         # also saves frames of the planner at work
import { execFileSync } from "node:child_process"
import { mkdirSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const BASE = process.env.BASE || `http://127.0.0.1:${process.env.PORT || 9600}`
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const ROOM = process.env.ROOM || `city-${`${Date.now()}`.slice(-6)}`
const INVITE = (process.env.PLANNER || "invite") === "invite"
const SHOTS = process.env.SHOTS || "/tmp"
const FRAMES = process.env.FRAMES
const [A, B] = [`${process.env.SESSION || "ci"}-a`, `${process.env.SESSION || "ci"}-b`] // agent-browser sessions
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ab = (s, ...a) => { try { return execFileSync(AB, a, { env: { ...process.env, AGENT_BROWSER_SESSION: s }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) } catch (e) { return `${e.stdout || ""}${e.stderr || ""}` } }
const evalIn = (s, js) => ab(s, "eval", "-b", Buffer.from(js).toString("base64"))
async function waitEval(s, js, label, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (/\btrue\b/.test(evalIn(s, js))) return true; await sleep(250) } console.log(`  TIMEOUT: ${label} (${s}): ${evalIn(s, js).trim()}`); return false }
let failures = 0; const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }
const synced = (s) => waitEval(s, "!!window.__yrb?.provider?.synced", "synced")
const shot = (s, name) => ab(s, "screenshot", "--full", `${SHOTS}/city-${name}.png`)
const states = "[...window.__yrb.provider.awareness.getStates().values()]"
const plannerHere = (s) => waitEval(s, `${states}.some(x => x?.planner)`, "planner present", 20000)
const tile = (k) => `window.__yrb.tiles.get('${k}')`
const allRoad = (cells) => cells.map((k) => `${tile(k)} === 'road' && window.__yrb.authors.get('${k}') === 'a:planner'`).join(" && ")
const range = (n, f) => Array.from({ length: n }, (_, i) => f(i))

console.log(`# city (${ROOM}, planner: ${INVITE ? "invited from the page" : "already running"})`)
for (const s of [A, B]) { ab(s, "open", `${BASE}/docs/${ROOM}/city`); ab(s, "set", "viewport", "1100", "1300") }
check("a synced", await synced(A))
check("b synced", await synced(B))
const nameA = evalIn(A, "window.__yrb.user.name").trim().replace(/"/g, "")

// --- both paint, both see ---------------------------------------------------
evalIn(A, "for (let x = 4; x < 12; x++) window.__yrb.paint(x, 4, 'road'); window.__yrb.paint(4, 3, 'house_red')")
check("b sees a's road and house", await waitEval(B, `${tile("11,4")} === 'road' && ${tile("4,3")} === 'house_red'`, "a's paint"))
check("b sees who painted them", await waitEval(B, `window.__yrb.authors.get('4,3') === 'h:${nameA}'`, "author"))
evalIn(B, "for (let y = 6; y < 12; y++) window.__yrb.paint(20, y, 'water')")
check("a sees b's water", await waitEval(A, `${tile("20,11")} === 'water'`, "b's paint"))

// A real pointer stroke in a: the stage's cell size comes from its box.
const [left, top, width, height] = (evalIn(A, "(() => { const r = document.getElementById('stage').getBoundingClientRect(); return [r.left, r.top, r.width, r.height].join(' ') })()").match(/[\d.]+/g) || []).map(Number)
const at = (x, y) => [Math.round(left + ((x + 0.5) / 48) * width), Math.round(top + ((y + 0.5) / 48) * height)]
evalIn(A, "window.__yrb.setTool('house_blue')")
ab(A, "mouse", "move", ...at(30, 8).map(String)); ab(A, "mouse", "down", "left"); ab(A, "mouse", "move", ...at(32, 8).map(String)); ab(A, "mouse", "up", "left")
check("a dragged three houses with the pointer", await waitEval(B, `${tile("30,8")} === 'house_blue' && ${tile("32,8")} === 'house_blue'`, "pointer paint"))

// --- presence -----------------------------------------------------------------
evalIn(A, "window.__yrb.moveTo(2, 2)")
evalIn(B, "window.__yrb.moveTo(45, 45)")
check("b sees a's character at 2,2", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}' && x.pos?.x === 2 && x.pos?.y === 2)`, "a's position"))
check("a draws a name tag for each person", await waitEval(A, "[...document.querySelectorAll('#tags .tag')].filter(el => !el.textContent.startsWith('Planner')).length === 2", "tags"))
ab(A, "press", "ArrowRight")
check("arrow keys move a", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}' && x.pos?.x === 3)`, "arrow"))
shot(A, "1-painted")

// --- the planner ------------------------------------------------------------
evalIn(A, "window.__yrb.paint(10, 20, 'house_red'); window.__yrb.paint(18, 20, 'house_orange')")
await sleep(300)
if (INVITE) ab(A, "click", ".invite-planner")
check("the planner shows up in a", await plannerHere(A))
check("the planner shows up in b", await plannerHere(B))
const between = range(7, (i) => `${11 + i},20`)
const claimed = waitEval(B, `window.__yrb.claims.size > 0`, "claims", 12000)
if (FRAMES) { mkdirSync(FRAMES, { recursive: true }); for (let i = 0; i < 24; i++) { ab(B, "screenshot", `${FRAMES}/frame-${String(i).padStart(2, "0")}.png`) } }
check("the planner claimed the cells first", await claimed)
check("a road joins the two houses, signed by the planner", await waitEval(B, allRoad(between), "road between houses", 30000))
check("the claims are cleared", await waitEval(A, "window.__yrb.claims.size === 0", "claims cleared"))
check("the planner says it is idle", await waitEval(A, `${states}.some(x => x?.planner && x.status === 'idle')`, "idle"))
shot(B, "2-road")

// An island: a house ringed by water gets a bridge to the road.
evalIn(A, "for (let x = 29; x <= 31; x++) for (let y = 25; y <= 27; y++) window.__yrb.paint(x, y, x === 30 && y === 26 ? 'house_blue' : 'water')")
check("the island house gets a bridge", await waitEval(B, "['30,25','31,26','30,27','29,26'].some(k => window.__yrb.tiles.get(k) === 'bridge' && window.__yrb.authors.get(k) === 'a:planner')", "bridge", 30000))
check("and a road on from it", await waitEval(B, "[...window.__yrb.tiles.entries()].filter(([k, v]) => v === 'road' && window.__yrb.authors.get(k) === 'a:planner').length >= 8", "road from bridge", 30000))
shot(B, "3-bridge")

// A sign is an instruction.
evalIn(B, "window.__yrb.placeSign(40, 30, 'PARK')")
check("a PARK sign gets a park beside it", await waitEval(A, "[...window.__yrb.tiles.entries()].some(([k, v]) => { const [x, y] = k.split(',').map(Number); return v === 'park' && Math.abs(x - 40) <= 2 && Math.abs(y - 30) <= 2 && window.__yrb.authors.get(k) === 'a:planner' })", "park", 30000))
check("the sign's text is drawn", await waitEval(A, "[...document.querySelectorAll('.sign-text')].some(el => el.textContent === 'PARK')", "sign label"))
shot(A, "4-sign")

// --- offline, then reconnect ------------------------------------------------
evalIn(A, "window.__yrb.goOffline()")
check("a says it is offline", await waitEval(A, "document.getElementById('status').textContent.includes('offline')", "offline status"))
evalIn(A, "for (let x = 0; x < 20; x++) window.__yrb.paint(x, 40, 'house_red')")
evalIn(B, "for (let x = 20; x < 40; x++) window.__yrb.paint(x, 42, 'park')")
check("a has its 20 tiles locally", await waitEval(A, `${range(20, (i) => `${tile(`${i},40`)} === 'house_red'`).join(" && ")}`, "a local"))
check("a counts the change waiting", await waitEval(A, "document.getElementById('status').textContent.includes('waiting to sync')", "waiting"))
await sleep(1500)
check("b does not see a's offline tiles yet", !/\btrue\b/.test(evalIn(B, `${tile("0,40")} === 'house_red'`)))
check("a does not see b's tiles yet", !/\btrue\b/.test(evalIn(A, `${tile("20,42")} === 'park'`)))
shot(A, "5-offline")
evalIn(A, "window.__yrb.reconnect()")
const forty = `${range(20, (i) => `${tile(`${i},40`)} === 'house_red'`).join(" && ")} && ${range(20, (i) => `${tile(`${20 + i},42`)} === 'park'`).join(" && ")}`
check("a reconnects and has all 40", await waitEval(A, forty, "a converged"))
check("b has all 40", await waitEval(B, forty, "b converged"))
check("a's outbox drained", await waitEval(A, "!window.__yrb.provider.hasPending && window.__yrb.provider.status === 'synced'", "drained"))
check("a's character is back for b", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}')`, "presence back"))
shot(B, "6-merged")

// --- attribution and the timelapse -------------------------------------------
evalIn(A, "window.__yrb.toggleAttribution(true)")
check("the attribution toggle is on", await waitEval(A, "document.getElementById('attribution').getAttribute('aria-pressed') === 'true' && !document.getElementById('legend').hidden", "attribution"))
shot(A, "7-attribution")
evalIn(A, "window.__yrb.toggleAttribution(false); document.getElementById('timelapse').open = true")
check("the timelapse loads every recorded update", await waitEval(A, "/after \\d+ of \\d+ updates/.test(document.getElementById('timelapse-caption').textContent) && Number(document.getElementById('timelapse-scrub').max) > 5", "timelapse", 20000))
evalIn(A, "(() => { const s = document.getElementById('timelapse-scrub'); s.value = 1; s.dispatchEvent(new Event('input')) })()")
check("the scrubber goes back to the start", await waitEval(A, "/after \\d+ of/.test(document.getElementById('timelapse-caption').textContent) && Number(document.getElementById('timelapse-scrub').value) === 1", "scrub"))
shot(A, "8-timelapse")
evalIn(A, "document.getElementById('timelapse').open = false")

console.log(`screenshots: ${SHOTS}/city-*.png`)
ab(A, "close"); ab(B, "close")
console.log(""); if (failures) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: city e2e (${ROOM})`); process.exit(0)
