// Multiple REAL Chrome browsers, driven by agent-browser across separate
// sessions, typing into the SAME document at the same time. Each browser types
// its own digit so every keystroke is accountable. Proves the full stack under
// concurrent real-browser editing: Tiptap -> @yrby/client provider ->
// ActionCable/yrby-actioncable -> store, converging byte-for-byte with no
// lost keystrokes.
//
//   PORT=3777 node agent_browsers.mjs        # 4 browsers (default)
//   PORT=3777 BROWSERS=6 PER=20 node agent_browsers.mjs
//
// Needs agent-browser (resolved from the sibling lexxy-realtime checkout's
// node_modules, or AB_BIN) and a Chromium it can drive.
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { dirname, resolve } from "node:path"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { serverText } from "./server_read.mjs"

const pexec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
// Prefer the self-contained local install (CI + a clean checkout), then an
// explicit AB_BIN override, then a sibling lexxy-realtime checkout.
const LOCAL_AB = resolve(here, "node_modules/.bin/agent-browser")
const AB =
  process.env.AB_BIN ||
  (existsSync(LOCAL_AB) ? LOCAL_AB : `${process.env.HOME}/Projects/lexxy-realtime/node_modules/.bin/agent-browser`)
const BASE = `http://localhost:${process.env.PORT || 3777}`
const ROOM = process.env.ROOM || `agent-${Date.now()}`
const N = Number(process.env.BROWSERS || 4)
const PER = Number(process.env.PER || 20)
const DIGITS = Array.from({ length: N }, (_, i) => String((i + 1) % 10))
const SESSIONS = Array.from({ length: N }, (_, i) => `ab${i + 1}`)

let failures = 0
const check = (label, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${label}`); if (!ok) failures++ }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const countChar = (s, c) => s.split(c).length - 1

const ab = (session, ...args) =>
  pexec(AB, args, { env: { ...process.env, AGENT_BROWSER_SESSION: session }, encoding: "utf8" })
    .then((r) => r.stdout.trim())
    .catch((e) => `${e.stdout || ""}${e.stderr || ""}`)

const docText = (s) => ab(s, "eval", `window.__yrb.ydoc.getXmlFragment("default").toString()`)
const synced = (s) => ab(s, "eval", `!!(window.__yrb && window.__yrb.provider.synced && window.__yrb.editor)`)
const awarenessSize = (s) => ab(s, "eval", `window.__yrb.provider.awareness.getStates().size`)

async function waitFor(label, fn, ms = 30000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await fn()) return true; await sleep(400) }
  check(`TIMEOUT: ${label}`, false)
  return false
}

// All browsers must agree, and every digit must be present in the expected count.
async function awaitConvergence(label, perDigit) {
  return waitFor(label, async () => {
    const texts = await Promise.all(SESSIONS.map(docText))
    if (!texts.every((t) => t === texts[0])) return false
    return DIGITS.every((d) => countChar(texts[0], d) === perDigit)
  })
}

async function typeRound(round, perDigit) {
  console.log(`\n--- Round ${round}: ${N} browsers each type '${PER}' chars at once ---`)
  // Real DOM focus per session (agent-browser keyboard targets the focused
  // element; Tiptap's programmatic focus alone doesn't take), then type all
  // sessions concurrently.
  await Promise.all(SESSIONS.map((s) => ab(s, "click", ".ProseMirror")))
  await Promise.all(SESSIONS.map((s, i) => ab(s, "keyboard", "type", DIGITS[i].repeat(PER))))

  const converged = await awaitConvergence(`all ${N} browsers converged (round ${round})`, perDigit)
  if (!converged) return
  const t = await docText(SESSIONS[0])
  check(`every browser identical after round ${round}`,
    (await Promise.all(SESSIONS.map(docText))).every((x) => x === t))
  DIGITS.forEach((d, i) =>
    check(`browser ${i + 1}: all ${perDigit} of '${d}' present (got ${countChar(t, d)})`, countChar(t, d) === perDigit))
  check(`characters conserved (${DIGITS.reduce((sum, d) => sum + countChar(t, d), 0)} == ${perDigit * N})`,
    DIGITS.reduce((sum, d) => sum + countChar(t, d), 0) === perDigit * N)
}

// 1) Open the same doc in N real browsers; wait until each is synced + present.
for (const s of SESSIONS) await ab(s, "open", `${BASE}/docs/${ROOM}`)
for (const s of SESSIONS) await waitFor(`${s} synced`, async () => /\btrue\b/.test(await synced(s)))
await Promise.all(SESSIONS.map((s) => ab(s, "click", ".ProseMirror"))) // set presence
check(`all ${N} browsers connected and synced`, true)
await waitFor(`awareness shows ${N} live users`, async () =>
  (await Promise.all(SESSIONS.map(awarenessSize))).every((n) => Number(n) === N))
check(`awareness shows ${N} live users`, (await Promise.all(SESSIONS.map(awarenessSize))).every((n) => Number(n) === N))

// 2) Two concurrent typing rounds, accumulating per-digit counts.
await typeRound(1, PER)
await typeRound(2, PER * 2)

// 3) The store (a different process's view, decoded from the server's CRDT
// state) reflects every keystroke — not just the in-browser replicas.
const onlyDigits = (s) => [...s].filter((c) => DIGITS.includes(c)).sort().join("")
const browserText = await docText(SESSIONS[0])
const storeText = await serverText(BASE, ROOM).catch(() => "")
DIGITS.forEach((d) =>
  check(`store reflects all ${PER * 2} of '${d}' (got ${countChar(storeText, d)})`,
    countChar(storeText, d) === PER * 2))
check(`store keystrokes match the browsers' converged text`,
  onlyDigits(storeText) === onlyDigits(browserText))
console.log("")

await ab(SESSIONS[0], "close", "--all")
if (failures > 0) { console.log(`\nFAILED: ${failures} check(s) failed`); process.exit(1) }
console.log(`\nPASS: ${N} real browsers typing at once (agent-browser): full convergence, every keystroke accounted for`)
