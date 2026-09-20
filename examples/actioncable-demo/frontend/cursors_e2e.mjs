// Two real browsers on the cursors page, and the eight guests between them.
// Both see the same signs; a sign posted in one shows in the other; a sign
// dragged in one moves in the other; each person's cursor shows in both.
// Then the guests: invited from one page, they show up in both, each
// standing at a sign it chose with a real Jev call; renaming a sign by
// typing starts a new round of decisions; dragging a sign moves the guests
// standing at it with no round; sending them home clears them from both.
// Asserts on the shared Yjs maps and presence at window.__yrb.
//
//   BASE=http://127.0.0.1:3779 node frontend/cursors_e2e.mjs
//
// The guest checks make real Jev calls (on the order of forty per run) and
// run whenever the server has a key: set TYPESAFE_API_KEY in this shell
// too, or LIVE_GUESTS=1, so the script knows. Without either, only the
// board is checked. SERVER_LOG=<path> also checks the server's decision
// log lines carry no sign text.
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const BASE = process.env.BASE || `http://127.0.0.1:${process.env.PORT || 3779}`
const room = process.env.ROOM || `cursors-${`${Date.now()}`.slice(-6)}`
const LIVE = process.env.LIVE_GUESTS === "1" || !!process.env.TYPESAFE_API_KEY
const SIGN_TEXTS = ["FREE PIZZA", "QUIET ROOM", "KARAOKE", "CAT CAFE", "PIZZA IS GONE", "SF RUBY CONF"]
const sessions = [`cursors-${process.pid}-a`, `cursors-${process.pid}-b`]
const [a, b] = sessions
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
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
    await sleep(150)
  }
  throw new Error(`Timed out: ${label}; guests=${JSON.stringify(evaluate(session, "window.__yrb?.guests()"))}`)
}
const synced = (session) => waitFor(session, "!!window.__yrb?.provider.synced", "document sync")
const texts = (session) => evaluate(session, "JSON.stringify([...window.__yrb.signs.entries()].map(([id, m]) => [id, m.get('text')]).sort())")
const guests = (session) => evaluate(session, "window.__yrb.guests()")
// The viewport rectangle of a sign, and a point inside it away from the textarea's text.
const box = (session, id) => evaluate(session, `(() => { const r = document.querySelector('[data-id=${id}]').getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height } })()`)
function drag(session, id, dx, dy) {
  const r = box(session, id)
  const [x, y] = [Math.round(r.x + 8), Math.round(r.y + 8)] // the card's corner: not the textarea
  ab(session, "mouse", "move", String(x), String(y))
  ab(session, "mouse", "down")
  try {
    for (let i = 1; i <= 4; i++) ab(session, "mouse", "move", String(Math.round(x + (dx * i) / 4)), String(Math.round(y + (dy * i) / 4)))
  } finally { ab(session, "mouse", "up") }
}

console.log(`# cursors (${room}, guests: ${LIVE ? "real Jev calls" : "skipped, no TYPESAFE_API_KEY"})`)
try {
  ab(a, "set", "viewport", "1280", "800")
  ab(a, "open", `${BASE}/docs/${room}/cursors?as=Ada`)
  await synced(a)
  await waitFor(a, "window.__yrb.signs.size === 3", "seeded signs")
  ab(b, "set", "viewport", "1280", "800")
  ab(b, "open", `${BASE}/docs/${room}/cursors?as=Grace`)
  await synced(b)
  await waitFor(b, "window.__yrb.signs.size === 3", "seeded signs in b")
  check("both browsers see the same three seeded signs", texts(a) === texts(b) && texts(a).includes("FREE PIZZA") && texts(a).includes("QUIET ROOM"))
  check("the seeded signs have fixed ids, so two first opens seed once", evaluate(a, "['s1','s2','s3'].every(id => window.__yrb.signs.has(id))"))

  // A sign posted by a real double-click on empty space and real typing.
  ab(a, "dblclick", "#stage")
  await waitFor(a, "window.__yrb.signs.size === 4 && document.activeElement?.tagName === 'TEXTAREA'", "a new sign, focused")
  ab(a, "keyboard", "type", "CAT CAFE")
  await waitFor(b, "[...window.__yrb.signs.values()].some(m => m.get('text') === 'CAT CAFE')", "the new sign in b")
  check("a sign posted in a shows up in b with its text", texts(a) === texts(b))

  // A drag in a moves the sign in b: the position lives in the document. The
  // board scales to fit, so a viewport pixel is 1/scale of a board unit.
  const scale = evaluate(a, "window.__yrb.scale()")
  const before = evaluate(a, "[window.__yrb.signs.get('s2').get('x'), window.__yrb.signs.get('s2').get('y')]")
  drag(a, "s2", -120, 80)
  const [ex, ey] = [Math.round(before[0] - 120 / scale), Math.round(before[1] + 80 / scale)]
  await waitFor(b, `Math.abs(window.__yrb.signs.get('s2').get('x') - ${ex}) <= 1 && Math.abs(window.__yrb.signs.get('s2').get('y') - ${ey}) <= 1`, "the drag in b")
  check("a sign dragged in a moves in b by the same amount", true)

  // Cursors: yours and the other person's, both drawn from awareness.
  const stage = evaluate(b, "(() => { const r = document.querySelector('#stage').getBoundingClientRect(); return [r.x, r.y] })()")
  ab(b, "mouse", "move", String(Math.round(stage[0] + 600)), String(Math.round(stage[1] + 300)))
  await waitFor(b, "[...document.querySelectorAll('.cursor.human .name')].some(el => el.textContent === 'Grace (you)')", "own cursor in b")
  check("your own cursor renders on your page", true)
  await waitFor(a, "[...document.querySelectorAll('.cursor.human .name')].some(el => el.textContent === 'Grace')", "Grace's cursor in a")
  check("the other person's cursor renders on your page", evaluate(a, "[...window.__yrb.provider.awareness.getStates().values()].some(s => s.user?.name === 'Grace' && s.cursor?.x > 0)"))

  let latencies = []
  let model = null
  if (LIVE) {
    ab(a, "click", "#invite")
    const arrived = "window.__yrb.guests().length === 8 && window.__yrb.guests().every(g => g.status !== 'arriving' && g.status !== 'deciding')"
    await waitFor(a, arrived, "8 guests settled in a", 10_000)
    await waitFor(b, arrived, "8 guests settled in b", 10_000)
    let states = guests(b)
    check("8 guests show up in both browsers within 10 s", states.length === 8 && guests(a).length === 8)
    check("every guest stands at a real sign or at the wall, and every decision names a real option", states.every((g) => (g.at === null || evaluate(b, `window.__yrb.signs.has('${g.at}')`)) && g.decision && (g.decision.sign === "stay" || evaluate(b, `window.__yrb.signs.has('${g.decision.sign}')`))))
    check("at least one guest walked to a sign", states.some((g) => g.at !== null))
    check("every decision came from a jev model with a latency", states.every((g) => typeof g.decision.model === "string" && g.decision.model.startsWith("jev") && typeof g.decision.ms === "number" && g.decision.ms > 0))
    check("the invite button shows the model once the guests are here", evaluate(a, "document.querySelector('#invite').textContent").startsWith("Guests are here · jev"))
    check("the HUD shows a round with a latency spread", /round 1 · 8 guests asked Jev · \d+–\d+ ms/.test(evaluate(a, "document.querySelector('#hud').textContent")))
    model = states[0].decision.model
    latencies.push(...states.map((g) => g.decision.ms))
    console.log(`  round 1: ${states.map((g) => `${g.name}→${g.at ? evaluate(b, `window.__yrb.signs.get('${g.at}').get('text')`) : "wall"}(${g.decision.p.toFixed(2)}, ${Math.round(g.decision.ms)}ms)`).join(", ")}`)

    // Renaming a sign by real typing starts a new round in every guest.
    const was = Object.fromEntries(states.map((g) => [g.name, { at: g.at, decidedAt: g.decision.at }]))
    ab(a, "click", "[data-id=s1] textarea")
    evaluate(a, "document.querySelector('[data-id=s1] textarea').select()")
    ab(a, "keyboard", "type", "PIZZA IS GONE")
    await waitFor(b, "window.__yrb.signs.get('s1').get('text') === 'PIZZA IS GONE'", "the rename in b")
    await waitFor(b, `window.__yrb.guests().some(g => g.decision && g.decision.at > ${Math.max(...states.map((g) => g.decision.at))})`, "a new round after the rename", 4_000)
    check("renaming FREE PIZZA to PIZZA IS GONE starts a new round within 4 s", true)
    await waitFor(b, `window.__yrb.guests().every(g => g.status === 'settled' || g.status === 'confused')`, "the round settles", 6_000)
    states = guests(b)
    const fresh = states.filter((g) => g.decision && g.decision.at > was[g.name].decidedAt)
    const moved = states.filter((g) => g.at !== was[g.name].at)
    console.log(`  round 2: ${fresh.length}/8 decided again; moved: ${moved.map((g) => `${g.name}→${g.at ? evaluate(b, `window.__yrb.signs.get('${g.at}').get('text')`) : "wall"}`).join(", ") || "none"}`)
    const networker = states.find((g) => g.name === "Networker")
    console.log(`  Networker is at ${networker.at ? evaluate(b, `window.__yrb.signs.get('${networker.at}').get('text')`) : "the wall"} (soft: model output is not ground truth)`)
    latencies.push(...fresh.map((g) => g.decision.ms))

    // Dragging a sign moves the guests standing at it, with no new round.
    const crowded = ["s1", "s2", "s3"].map((id) => [id, states.filter((g) => g.at === id).map((g) => g.name)]).sort((x, y) => y[1].length - x[1].length)[0]
    const [signId, names] = crowded
    check("some guests stand at one sign together", names.length >= 1)
    const targets = Object.fromEntries(names.map((n) => [n, evaluate(b, `window.__yrb.guestTarget('${n}')`)]))
    const newest = Math.max(...states.map((g) => g.decision?.at || 0))
    const at = evaluate(a, `[window.__yrb.signs.get('${signId}').get('x'), window.__yrb.signs.get('${signId}').get('y')]`)
    drag(a, signId, 90, -60)
    const [mx, my] = [Math.round(at[0] + 90 / scale) - at[0], Math.round(at[1] - 60 / scale) - at[1]]
    await waitFor(b, `Math.abs(window.__yrb.guestTarget('${names[0]}')[0] - ${targets[names[0]][0] + mx}) <= 1`, "the crowd's target follows the sign")
    check("dragging a sign moves its guests' targets by the same amount in the other browser", names.every((n) => { const t = evaluate(b, `window.__yrb.guestTarget('${n}')`); return Math.abs(t[0] - (targets[n][0] + mx)) <= 1 && Math.abs(t[1] - (targets[n][1] + my)) <= 1 }))
    await sleep(1500)
    check("dragging made no new decisions", guests(b).every((g) => (g.decision?.at || 0) <= newest))

    // Sending the guests home from the other browser clears them from both.
    ab(b, "click", "#home")
    await waitFor(a, "window.__yrb.guests().length === 0", "guests gone in a", 6_000)
    await waitFor(b, "window.__yrb.guests().length === 0", "guests gone in b", 6_000)
    check("sending the guests home clears them from both browsers within 6 s", evaluate(a, "window.__yrb.party.get('enabled') === false"))
    check("the invite is offered again", evaluate(a, "document.querySelector('#invite').textContent") === "Invite 8 Ruby guests")
  }

  for (const session of sessions) {
    const errors = ab(session, "errors")
    check(`browser ${session === a ? "a" : "b"} has no JavaScript errors`, !errors.errors?.length)
  }
  if (LIVE && process.env.SERVER_LOG) {
    const lines = readFileSync(process.env.SERVER_LOG, "utf8").split("\n").filter((l) => l.includes(`"event":"guest_decision"`) && l.includes(`"room":"${room}:cursors"`))
    const events = lines.map((l) => JSON.parse(l.slice(l.indexOf("{"))))
    check("the server logged each decision as a JSON line", events.length >= 16 && events.every((e) => e.event === "guest_decision" && e.guest && typeof e.status === "string"))
    check("no decision line carries a sign's text", lines.every((l) => !SIGN_TEXTS.some((t) => l.includes(t))))
    const ok = events.filter((e) => e.status === "ok")
    console.log(`  server log: ${events.length} decision lines, ${ok.length} ok, ${events.length - ok.length} errors`)
  }
  if (LIVE) console.log(`  jev: ${model}, ${latencies.length} decisions, ${Math.round(Math.min(...latencies))}–${Math.round(Math.max(...latencies))} ms, median ${Math.round([...latencies].sort((x, y) => x - y)[Math.floor(latencies.length / 2)])} ms`)
  console.log(`PASS: ${checks} cursors checks (${LIVE ? "real Jev decisions" : "board only"}); room=${room}`)
} finally {
  for (const session of sessions) {
    try { evaluate(session, "window.__yrb?.party.set('enabled', false)") } catch { /* Page may not have loaded. */ }
    try { ab(session, "close") } catch { /* Preserve the original failure. */ }
  }
}
