// Two real browsers on the city page, and the planner and the townsfolk
// between them. Both paint and see each other's tiles and characters; the
// camera pans and zooms; a shop two cells wide goes down as one key and the
// planner's road goes round it; the planner, invited from the page,
// connects two houses with a road, bridges to a house on an island, and
// plants a park where a sign asks for one; the townsfolk, woken from the
// page, walk the roads in every browser; one browser goes offline with a
// badge counting its queued changes, both keep painting, and everything
// merges on reconnect with the merged tiles flashing; two characters side
// by side wave; the attribution toggle tints the map; the timelapse replays
// the log. Asserts on the shared Yjs maps at window.__yrb, and takes a
// screenshot at each beat.
//
// With LIVE_MAYOR=1, against a server with a model key, the mayor is
// checked with the real model too: a sign in free words is read into a
// shop, a street is named after the sign beside it with the bell, and a
// person painting over the mayor's chosen site mid-build makes the planner
// yield. Skipped otherwise, so the check runs without a key.
//
//   PORT=9600 STORE_KIND=file bin/rails s -p 9600         # server
//   node frontend/city_e2e.mjs                            # invites the planner and the townsfolk from the page
//   PLANNER=process ROOM=x node frontend/city_e2e.mjs     # peers already running: bin/city-planner x, bin/city-life x
//   FRAMES=/tmp/frames node frontend/city_e2e.mjs         # also saves frames of the planner at work
//   LIVE_MAYOR=1 node frontend/city_e2e.mjs               # the mayor beats too, against a server with a key
import { execFileSync } from "node:child_process"
import { mkdirSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const BASE = process.env.BASE || `http://127.0.0.1:${process.env.PORT || 9600}`
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const ROOM = process.env.ROOM || `city-${`${Date.now()}`.slice(-6)}`
const INVITE = (process.env.PLANNER || "invite") === "invite"
const LIVE_MAYOR = process.env.LIVE_MAYOR === "1"
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
// The planner's roads: plain road, or cable car track where the hill is steep.
const plannerRoad = (k) => `(${tile(k)} === 'road' || ${tile(k)} === 'cable') && window.__yrb.authors.get('${k}') === 'a:planner'`
const allRoad = (cells) => cells.map(plannerRoad).join(" && ")
const range = (n, f) => Array.from({ length: n }, (_, i) => f(i))
const num = (s, js) => Number((evalIn(s, js).match(/-?[\d.]+/) || [NaN])[0])

console.log(`# city (${ROOM}, peers: ${INVITE ? "invited from the page" : "already running"})`)
for (const s of [A, B]) { ab(s, "open", `${BASE}/docs/${ROOM}/city`); ab(s, "set", "viewport", "1100", "1300") }
check("a synced", await synced(A))
check("b synced", await synced(B))
const nameA = evalIn(A, "window.__yrb.user.name").trim().replace(/"/g, "")

// --- the land ------------------------------------------------------------------
check("both pages agree on the terrain's seed", await waitEval(B, `Number.isInteger(window.__yrb.meta.get('seed')) && window.__yrb.meta.get('seed') === ${num(A, "window.__yrb.meta.get('seed')")}`, "seed"))
check("the bay lies along the east edge", /\btrue\b/.test(evalIn(A, "window.__yrb.terrain.water(95, 10) && !window.__yrb.terrain.water(2, 10)")))

// --- both paint, both see ---------------------------------------------------
evalIn(A, "for (let x = 4; x < 12; x++) window.__yrb.paint(x, 4, 'road'); window.__yrb.paint(4, 3, 'house_red')")
check("b sees a's road and house", await waitEval(B, `${tile("11,4")} === 'road' && ${tile("4,3")} === 'house_red'`, "a's paint"))
check("b sees who painted them", await waitEval(B, `window.__yrb.authors.get('4,3') === 'h:${nameA}'`, "author"))
evalIn(B, "for (let y = 6; y < 12; y++) window.__yrb.paint(20, y, 'water')")
check("a sees b's water", await waitEval(A, `${tile("20,11")} === 'water'`, "b's paint"))

// A shop two cells wide is one key at its corner; erasing any cell it
// covers takes the whole shop out.
evalIn(A, "window.__yrb.paint(14, 24, 'shop')")
check("b sees a's shop as one key with its footprint", await waitEval(B, `${tile("14,24")} === 'shop@2x2' && ${tile("15,25")} === undefined`, "shop key"))
evalIn(B, "window.__yrb.paint(15, 25, 'erase')")
check("erasing a covered cell removes the shop", await waitEval(A, `${tile("14,24")} === undefined`, "shop erased"))

// A real pointer stroke in a: the camera says where a cell is on screen.
evalIn(A, "window.__yrb.camera.zoomAt(2, 100, 100); window.__yrb.camera.centerOn(31, 8); window.__yrb.setTool('house_blue')")
await sleep(200)
const at = (x, y) => (evalIn(A, `(() => { const c = window.__yrb.camera, r = document.getElementById('stage').getBoundingClientRect(); return [r.left + ((${x} + 0.5) * 16 - c.x) * c.zoom, r.top + ((${y} + 0.5) * 16 - c.y) * c.zoom].map(Math.round).join(' ') })()`).match(/[\d.]+/g) || []).map(String)
ab(A, "mouse", "move", ...at(30, 8)); ab(A, "mouse", "down", "left"); ab(A, "mouse", "move", ...at(32, 8)); ab(A, "mouse", "up", "left")
check("a dragged three houses with the pointer", await waitEval(B, `${tile("30,8")} === 'house_blue' && ${tile("32,8")} === 'house_blue'`, "pointer paint"))

// --- the camera ----------------------------------------------------------------
const camBefore = evalIn(A, "JSON.stringify([window.__yrb.camera.x, window.__yrb.camera.y, window.__yrb.camera.zoom])")
evalIn(A, "window.__yrb.camera.panBy(96, 48)")
check("the camera pans", evalIn(A, "JSON.stringify([window.__yrb.camera.x, window.__yrb.camera.y, window.__yrb.camera.zoom])") !== camBefore)
evalIn(A, "document.getElementById('overlay').dispatchEvent(new WheelEvent('wheel', { deltaY: -300, clientX: 300, clientY: 700, bubbles: true, cancelable: true }))")
check("the wheel zooms in", await waitEval(A, "window.__yrb.camera.zoom > 2.05", "wheel zoom"))
evalIn(A, "window.__yrb.camera.zoomAt(1, 0, 0)")
check("zoom out shows more of the town", await waitEval(A, "window.__yrb.camera.zoom === 1 && (window.__yrb.camera.visible().x1 - window.__yrb.camera.visible().x0) > 40", "zoom out"))
evalIn(A, "document.getElementById('jump').click()")
check("jump to me centres the camera on my character", await waitEval(A, "(() => { const c = window.__yrb.camera, v = c.visible(), p = window.__yrb.pos; return p.x >= v.x0 && p.x <= v.x1 && p.y >= v.y0 && p.y <= v.y1 })()", "jump"))

// --- presence -----------------------------------------------------------------
evalIn(A, "window.__yrb.moveTo(2, 2)")
evalIn(B, "window.__yrb.moveTo(45, 45)")
check("b sees a's character at 2,2", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}' && x.pos?.x === 2 && x.pos?.y === 2)`, "a's position"))
check("a draws a name tag for each person", await waitEval(A, "[...document.querySelectorAll('#tags .tag')].filter(el => !el.textContent.startsWith('Planner')).length === 2", "tags"))
ab(A, "press", "ArrowRight")
check("arrow keys move a", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}' && x.pos?.x === 3)`, "arrow"))
evalIn(A, "window.__yrb.say('hello town'); window.__yrb.hop()")
check("b sees a's speech bubble and hop", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}' && x.say?.text === 'hello town' && x.hop > 0)`, "say and hop"))
evalIn(B, "window.__yrb.moveTo(4, 2)")
check("two characters side by side wave at each other", await waitEval(A, "window.__yrb.waving >= 2", "wave", 6000))
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
check("the HUD counts the planner's roads and shows what it said", await waitEval(A, "Number(document.getElementById('hud-roads').textContent) >= 7 && document.getElementById('hud-said').textContent !== '…'", "hud"))
evalIn(A, "window.__yrb.follow('planner')")
check("follow the planner brings its character into view", await waitEval(A, "(() => { const v = window.__yrb.camera.visible(), p = [...window.__yrb.provider.awareness.getStates().values()].find(s => s?.planner)?.pos; return document.getElementById('follow').getAttribute('aria-pressed') === 'true' && p && p.x >= v.x0 && p.x <= v.x1 && p.y >= v.y0 && p.y <= v.y1 })()", "follow", 8000))
evalIn(A, "window.__yrb.follow(null)")
shot(B, "2-road")

// A shop in the way: the road to a third house goes round it.
evalIn(A, "window.__yrb.paint(13, 29, 'shop'); window.__yrb.paint(10, 30, 'house_blue'); window.__yrb.paint(17, 30, 'house_red')")
check("the planner's road goes round the shop", await waitEval(B, `[...window.__yrb.tiles.entries()].filter(([k, v]) => (v === 'road' || v === 'cable') && window.__yrb.authors.get(k) === 'a:planner' && k.split(',')[1] >= 28).length >= 5 && ${tile("13,30")} === undefined && ${tile("14,30")} === undefined && ${tile("13,29")} === 'shop@2x2'`, "road round the shop", 30000))

// An island: a house ringed by water gets a bridge to the road.
evalIn(A, "for (let x = 29; x <= 31; x++) for (let y = 25; y <= 27; y++) window.__yrb.paint(x, y, x === 30 && y === 26 ? 'house_blue' : 'water')")
check("the island house gets a bridge", await waitEval(B, "['30,25','31,26','30,27','29,26'].some(k => window.__yrb.tiles.get(k) === 'bridge' && window.__yrb.authors.get(k) === 'a:planner')", "bridge", 30000))
check("and a road on from it", await waitEval(B, "[...window.__yrb.tiles.entries()].filter(([k, v]) => (v === 'road' || v === 'cable') && window.__yrb.authors.get(k) === 'a:planner').length >= 8", "road from bridge", 30000))
shot(B, "3-bridge")

// A sign is an instruction; a sign beside a road with a name is a label.
evalIn(B, "window.__yrb.placeSign(40, 30, 'PARK')")
check("a PARK sign gets a park beside it", await waitEval(A, "[...window.__yrb.tiles.entries()].some(([k, v]) => { const [x, y] = k.split(',').map(Number); return v === 'park' && Math.abs(x - 40) <= 2 && Math.abs(y - 30) <= 2 && window.__yrb.authors.get(k) === 'a:planner' })", "park", 30000))
check("the sign's text is drawn", await waitEval(A, "[...document.querySelectorAll('.sign-text')].some(el => el.textContent === 'PARK')", "sign label"))
evalIn(B, "window.__yrb.placeSign(7, 5, 'Elm Street')")
check("a name beside a road becomes a street label", await waitEval(A, "window.__yrb.labels.some(l => l.text === 'Elm Street' && !l.vertical)", "street label"))
shot(A, "4-sign")

// --- the townsfolk --------------------------------------------------------------
if (INVITE) ab(A, "click", ".invite-life")
check("the townsfolk show up in b, in awareness only", await waitEval(B, `${states}.some(x => x?.life && x.peds?.length >= 12 && Array.isArray(x.smoke) && typeof x.clock === 'number')`, "life", 20000))
const walkers = evalIn(B, "JSON.stringify(window.__yrb.life.peds.map(p => p.slice(2, 4)))")
check("pedestrians walk the roads the planner built", await waitEval(B, `JSON.stringify(window.__yrb.life.peds.map(p => p.slice(2, 4))) !== ${JSON.stringify(walkers)} && window.__yrb.life.peds.every(([,, x, y]) => ['road', 'cable', 'bridge'].includes(window.__yrb.tiles.get(x + ',' + y)))`, "walking", 8000))
check("the document holds no footsteps", /\btrue\b/.test(evalIn(B, "[...window.__yrb.tiles.values()].every(v => typeof v === 'string') && !window.__yrb.ydoc.share.has('peds') && !window.__yrb.ydoc.share.has('life')")))
evalIn(B, "window.__yrb.camera.zoomAt(2.5, 0, 0); window.__yrb.camera.centerOn(14, 20)")
await sleep(1200)
shot(B, "5-life")

// --- the mayor, with a real model --------------------------------------------
// Only with LIVE_MAYOR=1: the server needs a model key. Three beats: a
// sign in free words becomes a shop; a street with a wish beside it gets
// its name from the mayor, with the bell; a person paints over the site
// the mayor chose while the planner is on its way, and it yields.
if (LIVE_MAYOR) {
  const near = (k, r, test) => `[...window.__yrb.tiles.entries()].some(([k, v]) => { const [x, y] = k.split(',').map(Number); const [sx, sy] = '${k}'.split(',').map(Number); return Math.abs(x - sx) <= ${r} && Math.abs(y - sy) <= ${r} && (${test}) })`
  const t0 = Date.now()
  evalIn(A, "for (let x = 60; x < 66; x++) for (let y = 61; y < 66; y++) window.__yrb.paint(x, y, 'water'); for (let x = 50; x < 60; x++) window.__yrb.paint(x, 62, 'road')")
  evalIn(B, "window.__yrb.placeSign(58, 60, 'a cozy bookshop by the water')")
  check("live: the mayor reads a sign in free words as SHOP", await waitEval(A, "window.__yrb.readings.get('58,60') === 'SHOP'", "reading", 30000))
  console.log(`  read in ${((Date.now() - t0) / 1000).toFixed(1)}s`)
  check("live: the planner opens a shop beside the sign", await waitEval(B, near("58,60", 4, "v === 'shop@2x2' && window.__yrb.authors.get(k) === 'a:planner'"), "shop", 45000))

  // A street of ten with four houses on it, and a sign asking for a name.
  evalIn(A, "for (let x = 70; x < 80; x++) window.__yrb.paint(x, 70, 'road'); for (const x of [71, 73, 75, 77]) window.__yrb.paint(x, 69, 'house_red')")
  evalIn(B, "window.__yrb.placeSign(74, 71, 'name this street after Ada')")
  check("live: the mayor reads the naming sign", await waitEval(A, "['NAME', 'ROAD', 'none'].includes(window.__yrb.readings.get('74,71'))", "naming sign read", 30000))
  const reading = evalIn(A, "window.__yrb.readings.get('74,71')").trim().replace(/"/g, "")
  console.log(`  the naming sign read as ${reading}`)
  if (reading === "none") {
    // The model took the sign for a name: it labels the street itself, cut to a label's length.
    check("live: the sign's own text labels the street", await waitEval(A, "window.__yrb.labels.some(l => l.text === 'name this street after Ada'.slice(0, 24))", "label"))
  } else {
    const mayorSign = near("74,71", 4, "v === 'sign' && window.__yrb.authors.get(k) === 'a:mayor' && window.__yrb.signs.get(k)")
    check("live: the mayor names the street with a sign of its own", await waitEval(B, mayorSign, "mayor's name", 75000))
    const name = evalIn(B, "[...window.__yrb.signs.entries()].find(([k]) => window.__yrb.authors.get(k) === 'a:mayor' && Math.abs(k.split(',')[0] - 74) <= 4 && Math.abs(k.split(',')[1] - 71) <= 4)?.[1]").trim().replace(/"/g, "")
    console.log(`  the mayor named it ${JSON.stringify(name)} (${/ada/i.test(name) ? "after Ada, as asked" : "not after Ada"})`)
    check("live: the name runs along the road as a label", await waitEval(B, `window.__yrb.labels.some(l => l.text === ${JSON.stringify(name)})`, "street label"))
    check("live: the bell rings for the mayor's sign", await waitEval(B, "window.__yrb.sound.log.includes('bell')", "bell"))
  }
  ab(B, "set", "viewport", "1100", "900", "2")
  evalIn(B, "window.__yrb.camera.zoomAt(2.5, 0, 0); window.__yrb.camera.centerOn(75, 69); document.getElementById('stage').scrollIntoView({ block: 'start' }); window.scrollBy(0, -4)")
  await sleep(1200)
  ab(B, "screenshot", `${SHOTS}/city-8-mayor.png`)
  ab(B, "set", "viewport", "1100", "1300")

  // Far from where the planner stands, another shop; the moment it claims
  // the site, a paints over it, and the planner yields.
  evalIn(B, "window.__yrb.placeSign(10, 84, 'somewhere to buy fresh bread')")
  check("live: the mayor reads the second sign as SHOP", await waitEval(A, "window.__yrb.readings.get('10,84') === 'SHOP'", "second reading", 30000))
  check("live: the planner claims the site", await waitEval(A, "[...window.__yrb.claims.keys()].some(k => Math.abs(k.split(',')[0] - 10) <= 4 && Math.abs(k.split(',')[1] - 84) <= 4)", "claim", 20000))
  const claimedKey = evalIn(A, "[...window.__yrb.claims.keys()].find(k => Math.abs(k.split(',')[0] - 10) <= 4 && Math.abs(k.split(',')[1] - 84) <= 4)").trim().replace(/"/g, "")
  evalIn(A, `window.__yrb.paint(${claimedKey}, 'flowers')`)
  check("live: the planner yields to the person who painted over its site", await waitEval(B, `${states}.some(x => x?.planner && /^yielding to /.test(x.status))`, "yield", 15000))
  check("live: the claims are released", await waitEval(B, "window.__yrb.claims.size === 0", "claims released"))
  check("live: the person's flowers stay on the site", await waitEval(B, `${tile(claimedKey)} === 'flowers'`, "flowers"))
  check("live: no shop was built over them", !/\btrue\b/.test(evalIn(B, `${tile(claimedKey)} === 'shop@2x2'`)))
  evalIn(B, "window.__yrb.camera.zoomAt(2.5, 0, 0); window.__yrb.camera.centerOn(14, 20)")
}

// --- offline, then reconnect ------------------------------------------------
evalIn(A, "window.__yrb.goOffline()")
check("a says it is offline", await waitEval(A, "document.getElementById('status').textContent.includes('offline')", "offline status"))
evalIn(A, "for (let x = 0; x < 20; x++) window.__yrb.paint(x, 40, 'house_red')")
evalIn(B, "for (let x = 20; x < 40; x++) window.__yrb.paint(x, 42, 'park')")
check("a has its 20 tiles locally", await waitEval(A, `${range(20, (i) => `${tile(`${i},40`)} === 'house_red'`).join(" && ")}`, "a local"))
check("a counts the change waiting", await waitEval(A, "document.getElementById('status').textContent.includes('waiting to sync')", "waiting"))
check("the badge counts the queued changes", await waitEval(A, "!document.getElementById('offline-badge').hidden && document.getElementById('offline-badge').textContent === 'OFFLINE · 20 changes queued'", "badge"))
await sleep(1500)
check("b does not see a's offline tiles yet", !/\btrue\b/.test(evalIn(B, `${tile("0,40")} === 'house_red'`)))
check("a does not see b's tiles yet", !/\btrue\b/.test(evalIn(A, `${tile("20,42")} === 'park'`)))
shot(A, "6-offline")
evalIn(A, "window.__yrb.reconnect()")
const forty = `${range(20, (i) => `${tile(`${i},40`)} === 'house_red'`).join(" && ")} && ${range(20, (i) => `${tile(`${20 + i},42`)} === 'park'`).join(" && ")}`
check("a reconnects and has all 40", await waitEval(A, forty, "a converged"))
check("b has all 40", await waitEval(B, forty, "b converged"))
check("the tiles that came from b flash in a", await waitEval(A, "window.__yrb.flashed >= 20", "flash"))
check("a's outbox drained", await waitEval(A, "!window.__yrb.provider.hasPending && window.__yrb.provider.status === 'synced'", "drained"))
check("a's character is back for b", await waitEval(B, `${states}.some(x => x?.user?.name === '${nameA}')`, "presence back"))
check("the badge is gone", /\btrue\b/.test(evalIn(A, "document.getElementById('offline-badge').hidden === true")))
shot(B, "7-merged")

// --- attribution, sound, and the timelapse --------------------------------------
evalIn(A, "window.__yrb.toggleAttribution(true)")
check("the attribution toggle is on, with a legend", await waitEval(A, "document.getElementById('attribution').getAttribute('aria-pressed') === 'true' && !document.getElementById('legend').hidden && document.getElementById('legend').textContent.includes('mayor')", "attribution"))
shot(A, "8-attribution")
evalIn(A, "document.getElementById('sound').click()")
check("sound is off until the toggle", await waitEval(A, "document.getElementById('sound').getAttribute('aria-pressed') === 'true' && window.__yrb.sound.on === true", "sound"))
evalIn(A, "document.getElementById('sound').click(); window.__yrb.toggleAttribution(false); document.getElementById('timelapse').open = true")
check("the timelapse loads every recorded update", await waitEval(A, "/after \\d+ of \\d+ updates/.test(document.getElementById('timelapse-caption').textContent) && Number(document.getElementById('timelapse-scrub').max) > 5", "timelapse", 20000))
evalIn(A, "(() => { const s = document.getElementById('timelapse-scrub'); s.value = 1; s.dispatchEvent(new Event('input')) })()")
check("the scrubber goes back to the start", await waitEval(A, "/after \\d+ of/.test(document.getElementById('timelapse-caption').textContent) && Number(document.getElementById('timelapse-scrub').value) === 1", "scrub"))
shot(A, "9-timelapse")
evalIn(A, "document.getElementById('timelapse').open = false")

console.log(`screenshots: ${SHOTS}/city-*.png`)
ab(A, "close"); ab(B, "close")
console.log(""); if (failures) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: city e2e (${ROOM})`); process.exit(0)
