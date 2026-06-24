// The harder multi-user cases, driven through REAL Chrome via agent-browser:
// concurrent RICH-TEXT merges (marks + block types, not just plain typing) and
// CURSOR/PRESENCE fidelity (named remote carets, selection highlights, cursors
// surviving concurrent edits, and presence reaping on disconnect). Complements
// agent_browsers.mjs, which proves plain-keystroke convergence.
//
//   PORT=3777 node agent_collab.mjs
//
// Needs agent-browser (local install, AB_BIN, or a sibling lexxy-realtime
// checkout) and a Chromium it can drive. Use a single-process server (the async
// cable adapter relays awareness in-process); a Redis-backed cluster works too.
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
const BASE = `http://localhost:${process.env.PORT || 3777}`
const ROOM = process.env.ROOM || `collab-${Date.now()}`

// Deterministic identities so cursor-label assertions don't fight the demo's
// random name/color picker.
const USERS = [
  { session: "collabA", name: "Alice", color: "#f87171" },
  { session: "collabB", name: "Bob", color: "#22d3ee" },
  { session: "collabC", name: "Carol", color: "#4ade80" },
]
const [ALICE, BOB, CAROL] = USERS

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
const html = (s) => js(s, `window.__yrb.editor.getHTML()`)
const labels = (s) => js(s, `Array.from(document.querySelectorAll(".collaboration-cursor__label")).map(e => e.textContent)`)
const hasSelection = (s) => js(s, `!!document.querySelector(".ProseMirror-yjs-selection")`)
const awarenessSize = (s) => js(s, `window.__yrb.provider.awareness.getStates().size`)

async function waitFor(label, fn, ms = 30000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await fn()) return true; await sleep(400) }
  check(`TIMEOUT: ${label}`, false)
  return false
}

// 1) Three real browsers, same doc, synced, with stable identities + presence.
for (const u of USERS) await ab(u.session, "open", `${BASE}/docs/${ROOM}`)
for (const u of USERS) {
  await waitFor(`${u.name} synced`, async () =>
    /\btrue\b/.test(await ab(u.session, "eval", `!!(window.__yrb && window.__yrb.provider.synced && window.__yrb.editor)`)))
}
// Pin each browser's collaboration identity (name + color).
for (const u of USERS) await js(u.session, `window.__yrb.editor.commands.updateUser({ name: ${JSON.stringify(u.name)}, color: ${JSON.stringify(u.color)} })`)
// Real focus so each is a live presence.
await Promise.all(USERS.map((u) => ab(u.session, "click", ".ProseMirror")))
await waitFor("awareness shows all 3 users", async () =>
  (await Promise.all(USERS.map((u) => awarenessSize(u.session)))).every((n) => n === 3))
check("3 browsers connected, synced, present", true)

// 2) Concurrent RICH-TEXT merge: each user appends a differently-formatted block
//    at the same time. Convergence must keep every mark/block type.
await Promise.all([
  js(ALICE.session, `window.__yrb.editor.chain().focus("end").insertContent("<p><strong>BOLD-Alice</strong></p>").run()`),
  js(BOB.session, `window.__yrb.editor.chain().focus("end").insertContent("<p><em>ITALIC-Bob</em></p>").run()`),
  js(CAROL.session, `window.__yrb.editor.chain().focus("end").insertContent("<h2>HEAD-Carol</h2>").run()`),
])
const markers = ["<strong>BOLD-Alice</strong>", "<em>ITALIC-Bob</em>", "HEAD-Carol"]
await waitFor("rich-text converged across all 3", async () => {
  const htmls = await Promise.all(USERS.map((u) => html(u.session)))
  return htmls.every((h) => h === htmls[0]) && markers.every((m) => htmls[0].includes(m))
})
{
  const htmls = await Promise.all(USERS.map((u) => html(u.session)))
  check("all 3 editors identical after concurrent rich-text edits", htmls.every((h) => h === htmls[0]))
  markers.forEach((m) => check(`formatting survived the merge: ${m.replace(/<[^>]+>/g, "")}`, htmls[0].includes(m)))
}

// 3) CURSOR fidelity: Alice selects a range; Bob and Carol must render her named
//    caret AND her selection highlight.
await js(ALICE.session, `window.__yrb.editor.chain().focus().setTextSelection({ from: 1, to: 6 }).run()`)
for (const viewer of [BOB, CAROL]) {
  await waitFor(`${viewer.name} sees Alice's named caret`, async () =>
    (await labels(viewer.session))?.includes("Alice"))
  check(`${viewer.name} renders Alice's remote caret labelled "Alice"`, (await labels(viewer.session)).includes("Alice"))
  check(`${viewer.name} renders Alice's selection highlight`, (await hasSelection(viewer.session)) === true)
}

// 4) The remote caret SURVIVES a concurrent edit by someone else.
await js(BOB.session, `window.__yrb.editor.chain().focus("end").insertContent(" bob-edits").run()`)
await sleep(800)
check("Alice's caret still present in Bob's view after Bob edits", (await labels(BOB.session)).includes("Alice"))

// 5) PRESENCE REAPING: Alice disconnects (only her session); her caret must
//    disappear for the rest.
await ab(ALICE.session, "close")
// The user-visible signal is the caret disappearing, which happens well under
// the client-side timeout. (The awareness *entry* itself can linger in the local
// Map until y-protocols' 30s outdated-timeout — standard plumbing, not a
// yrb-lite behavior — so we don't assert on Map size here.)
const reaped = await waitFor("Alice's caret removed from Bob after she leaves", async () =>
  !(await labels(BOB.session)).includes("Alice"))
check("Alice's caret reaped from Bob on disconnect", reaped)
check("Bob and Carol remain present after Alice leaves",
  (await awarenessSize(BOB.session)) >= 2)

await ab(BOB.session, "close", "--all") // --all tears down every remaining session
console.log("")
if (failures > 0) { console.log(`\nFAILED: ${failures} check(s) failed`); process.exit(1) }
console.log("PASS: rich-text merges + cursor/selection fidelity + presence reaping (agent-browser)")
