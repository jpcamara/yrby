// Real Chrome input and a real Ruby peer. Run against the local demo:
//   BASE=http://127.0.0.1:3778 node pixels_e2e.mjs
//   LIVE_ARTIST=1 BASE=http://127.0.0.1:3778 node pixels_e2e.mjs
// The live path needs a configured server-side model key and makes paid calls.
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const BASE = process.env.BASE || "http://127.0.0.1:3778"
const room = process.env.ROOM || `pixels-test-${Date.now()}`
const LIVE = process.env.LIVE_ARTIST === "1"
const sessions = [`pixel-${process.pid}-a`, `pixel-${process.pid}-b`]
const [a, b] = sessions
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const shots = process.env.SHOTS || "/tmp"
let checks = 0

function ab(session, ...args) {
  const output = execFileSync(AB, ["--session", session, "--json", ...args], {
    encoding: "utf8", timeout: 25_000, stdio: ["ignore", "pipe", "pipe"],
  })
  const result = JSON.parse(output)
  assert.ok(result.success, result.error || output)
  return result.data
}
const evaluate = (session, expression) => ab(session, "eval", expression).result
function check(label, condition) {
  assert.ok(condition, label)
  checks++
  console.log(`ok ${checks}: ${label}`)
}
async function waitFor(session, expression, label, timeout = 15_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (evaluate(session, expression)) return
    await sleep(180)
  }
  throw new Error(`Timed out: ${label}; state=${JSON.stringify(evaluate(session, "window.__yrb?.mural.toJSON()"))}`)
}
const synced = (session) => waitFor(session, "!!window.__yrb?.provider.synced", "document sync")
const state = (session) => evaluate(session, "JSON.stringify([...window.__yrb.pixels.entries()].sort())")
async function converge() {
  await waitFor(b, `JSON.stringify([...window.__yrb.pixels.entries()].sort()) === ${JSON.stringify(state(a))}`, "same human pixels")
}
function choose(session, index) { ab(session, "click", `#palette .swatch:nth-child(${index + 1})`) }
function stroke(session, from, to = from) {
  const r = evaluate(session, "(() => {const r=document.querySelector('#mural-canvas').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()")
  const point = ([x, y]) => [String(Math.round(r.x + (x + 0.5) * r.width / 64)), String(Math.round(r.y + (y + 0.5) * r.height / 32))]
  ab(session, "mouse", "move", ...point(from))
  ab(session, "mouse", "down")
  try { if (from !== to) ab(session, "mouse", "move", ...point(to)) }
  finally { ab(session, "mouse", "up") }
}

console.log(`# Pixel Bay ${room} (${LIVE ? "live artist" : "human peers"})`)
try {
  for (const session of sessions) {
    ab(session, "set", "viewport", "1440", "1000")
    ab(session, "open", `${BASE}/docs/${room}/pixels`)
    await synced(session)
  }
  check("both browsers load the same 2048-pixel scene", sessions.every((s) => evaluate(s, "window.__yrb.scene.size === 2048")))
  await waitFor(a, "window.__yrb.provider.awareness.getStates().size >= 2", "other painter present")
  check("both painters have live presence", true)

  choose(a, 7)
  stroke(a, [2, 2], [6, 2])
  await waitFor(b, "[2,3,4,5,6].every(x=>window.__yrb.pixels.get(`${x},2`)===7)", "interpolated stroke arrives")
  check("a real pointer drag paints every pixel along the stroke in both browsers", true)
  choose(b, 8)
  stroke(b, [10, 3])
  await waitFor(a, "window.__yrb.pixels.get('10,3')===8", "second painter's mark")
  ab(a, "click", "#undo-stroke")
  await converge()
  check("undo removes only this painter's stroke and preserves the other painter", evaluate(b, "[2,3,4,5,6].every(x=>!window.__yrb.pixels.has(`${x},2`)) && window.__yrb.pixels.get('10,3')===8"))

  choose(a, 6)
  stroke(a, [3, 4])
  choose(b, 9)
  stroke(b, [12, 4])
  await converge()
  check("independent edits merge", evaluate(b, "window.__yrb.pixels.get('3,4')===6 && window.__yrb.pixels.get('12,4')===9"))
  ab(a, "click", "#eraser-tool")
  stroke(a, [3, 4])
  await converge()
  check("eraser restores the scene using a protected human pixel", evaluate(b, "window.__yrb.pixels.has('3,4') && window.__yrb.pixels.get('3,4')===window.__yrb.scene.get('3,4')"))

  // Explicit disconnection exercises queued edits, followed by a fresh sync.
  evaluate(a, "window.__yrb.provider.disconnect()")
  choose(a, 15)
  stroke(a, [4, 6])
  choose(b, 10)
  stroke(b, [9, 6])
  evaluate(a, "window.__yrb.provider.connect()")
  await synced(a)
  await converge()
  check("edits made while disconnected merge with another painter on reconnect", evaluate(b, "window.__yrb.pixels.get('4,6')===15 && window.__yrb.pixels.get('9,6')===10"))

  const durable = state(a)
  ab(a, "reload")
  await synced(a)
  check("paint survives a page reload", state(a) === durable)
  ab(a, "fill", "#artist-brief", "Add a tiny red ruby gem in the open sky, around x=22,y=5. Leave the bridge and people's marks intact.")
  ab(a, "press", "Tab")
  await waitFor(b, "window.__yrb.mural.get('brief')?.startsWith('Add a tiny red ruby gem')", "shared direction")
  check("the artist direction is shared", true)

  if (LIVE) {
    ab(a, "click", "#invite-artist-button")
    await waitFor(b, "[...window.__yrb.provider.awareness.getStates().values()].some(x=>x.artist)", "Ruby joined", 20_000)
    await waitFor(b, "window.__yrb.mural.get('turns')>=1 || window.__yrb.mural.get('phase')==='error'", "first real model turn", 120_000)
    check("a live model creates a validated pixel patch", evaluate(b, "window.__yrb.mural.get('turns')>=1 && window.__yrb.artistPixels.size>0 && window.__yrb.mural.get('phase')!=='error'"))
    const duplicate = evaluate(b, "fetch(document.querySelector('#invite-artist').action,{method:'POST',headers:{'X-CSRF-Token':document.querySelector('meta[name=csrf-token]').content}}).then(async r=>{await r.body?.cancel();return r.status})")
    check("a duplicate invitation is rejected", duplicate === 409)
    const turns = evaluate(b, "window.__yrb.mural.get('turns')")
    console.log(`artist: ${evaluate(b, "window.__yrb.mural.get('note')")}`)
    const point = evaluate(b, "[...window.__yrb.artistPixels.keys()].find(k=>!window.__yrb.pixels.has(k)).split(',').map(Number)")
    choose(b, 11)
    stroke(b, point)
    await waitFor(a, `window.__yrb.mural.get('turns')>${turns} || window.__yrb.mural.get('phase')==='error'`, "unprompted reaction to human paint", 120_000)
    console.log(`after human paint: ${JSON.stringify(evaluate(a, "window.__yrb.mural.toJSON()"))}`)
    check("Ruby reacts to a human painting over its work without another prompt", evaluate(a, `window.__yrb.mural.get('turns')>${turns} && window.__yrb.mural.get('phase')!=='error'`))
    check("the human's change takes priority over artist paint", evaluate(a, `window.__yrb.pixels.get('${point.join(",")}')===11`))
    check("the rendered canvas shows the human color over the artist layer", evaluate(a, `(() => {const c=document.querySelector('#mural-canvas');return [...c.getContext('2d').getImageData(Math.floor((${point[0]}+.5)*c.width/64),Math.floor((${point[1]}+.5)*c.height/32),1,1).data].join(',')==='120,179,139,255'})()`))
    console.log(`artist: ${evaluate(a, "window.__yrb.mural.get('note')")}`)

    ab(a, "fill", "#artist-brief", "Add a few golden sparkles beside the ruby, without changing existing human paint.")
    ab(a, "press", "Tab")
    await waitFor(a, "window.__yrb.mural.get('phase')==='thinking'", "inference starts", 20_000)
    ab(b, "click", "#remove-artist")
    await waitFor(a, "![...window.__yrb.provider.awareness.getStates().values()].some(x=>x.artist)", "artist leaves while thinking", 15_000)
    const afterStop = evaluate(a, "JSON.stringify(window.__yrb.artistPixels.toJSON())")
    await sleep(1500)
    check("another participant can stop an in-flight artist without later painting", evaluate(a, "window.__yrb.mural.get('enabled')===false") && evaluate(a, "JSON.stringify(window.__yrb.artistPixels.toJSON())") === afterStop)
  }

  ab(a, "screenshot", "--full", `${shots}/pixel-mural-desktop.png`)
  ab(b, "set", "viewport", "390", "844")
  await sleep(200)
  check("mobile view has no horizontal overflow", evaluate(b, "document.documentElement.scrollWidth<=innerWidth"))
  ab(b, "screenshot", "--full", `${shots}/pixel-mural-mobile.png`)
  for (const session of sessions) {
    const errors = ab(session, "errors")
    check("browser has no JavaScript errors", !errors.errors?.length)
  }
  console.log(`PASS: ${checks} pixel mural checks (${LIVE ? "live RubyLLM artist" : "two human peers"}); room=${room}`)
} finally {
  for (const session of sessions) {
    try { evaluate(session, "window.__yrb?.mural.set('enabled',false)") } catch { /* Page may not have loaded. */ }
    try { ab(session, "close") } catch { /* Preserve original test failure. */ }
  }
}
