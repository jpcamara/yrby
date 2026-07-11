// The Rhino page (Tiptap 3 via rhino-editor, bound with Tiptap's own
// Collaboration extensions) through REAL Chrome: two browsers on the same document, concurrent
// typing, byte-for-byte convergence, remote carets, undo staying local, and
// the ActionText save — the server replays the durable store into a Y::Doc
// and renders it with Y::Tiptap, so the persisted rich text is derived
// from the CRDT, not from any browser's serialized HTML. Complements
// agent_browsers.mjs (the Tiptap 2 page) — same protocol, third front end.
//
//   PORT=3777 node rhino_e2e.mjs
//
// Needs agent-browser (local install, AB_BIN, or a sibling lexxy-realtime
// checkout) and a Chromium it can drive.
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
const ROOM = process.env.ROOM || `rhino-${Date.now()}`
const SESSIONS = ["rhinoA", "rhinoB"]
const [A, B] = SESSIONS
const PER = Number(process.env.PER || 15)

let failures = 0
const check = (label, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${label}`); if (!ok) failures++ }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const countChar = (s, c) => s.split(c).length - 1

const ab = (session, ...args) =>
  pexec(AB, args, { env: { ...process.env, AGENT_BROWSER_SESSION: session }, encoding: "utf8" })
    .then((r) => r.stdout.trim())
    .catch((e) => `${e.stdout || ""}${e.stderr || ""}`)

// The Rhino page binds its own fragment on the shared doc.
const docText = (s) => ab(s, "eval", `window.__yrb.ydoc.getXmlFragment("rhino").toString()`)
const synced = (s) => ab(s, "eval", `!!(window.__yrb && window.__yrb.provider.synced && window.__yrb.editor)`)

async function waitFor(label, fn, ms = 30000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (await fn()) return true; await sleep(400) }
  check(`TIMEOUT: ${label}`, false)
  return false
}

// 1) Two real browsers on the same Rhino document, synced.
for (const s of SESSIONS) await ab(s, "open", `${BASE}/docs/${ROOM}/rhino`)
for (const s of SESSIONS) await waitFor(`${s} synced`, async () => /\btrue\b/.test(await synced(s)))
check("both browsers connected and synced", true)

// 2) Concurrent typing: each browser its own digit, every keystroke
// accountable, both sides byte-identical afterwards.
await Promise.all(SESSIONS.map((s) => ab(s, "click", ".ProseMirror")))
await Promise.all([ab(A, "keyboard", "type", "1".repeat(PER)), ab(B, "keyboard", "type", "2".repeat(PER))])
await waitFor("both browsers converged after concurrent typing", async () => {
  const [ta, tb] = await Promise.all(SESSIONS.map(docText))
  return ta === tb && countChar(ta, "1") === PER && countChar(ta, "2") === PER
})
const t = await docText(A)
check(`all ${PER} of '1' present (got ${countChar(t, "1")})`, countChar(t, "1") === PER)
check(`all ${PER} of '2' present (got ${countChar(t, "2")})`, countChar(t, "2") === PER)
check("both browsers byte-identical", t === (await docText(B)))

// 3) Remote carets: each browser shows the other's CollaborationCaret.
await waitFor("remote carets visible in both browsers", async () => {
  const seen = await Promise.all(
    SESSIONS.map((s) => ab(s, "eval", `document.querySelectorAll(".collaboration-carets__caret").length`))
  )
  return seen.every((n) => Number(n) >= 1)
})
check("remote carets rendered", true)

// 4) Undo stays local: A undoes its own typing (yUndoPlugin), B's content
// survives. Rhino's built-in UndoRedo is disabled, so Mod-z hits the Yjs
// undo. ProseMirror's Mod is Meta on macOS and Control elsewhere — ask the
// browser, or this test only passes on a Mac.
const isMac = /\btrue\b/.test(await ab(A, "eval", `navigator.platform.startsWith("Mac")`))
const undoCombo = isMac ? "Meta+z" : "Control+z"
await ab(A, "click", ".ProseMirror")
for (let i = 0; i < PER; i++) await ab(A, "press", undoCombo)
await waitFor("undo removed A's characters but kept B's", async () => {
  const ta = await docText(A)
  return countChar(ta, "1") === 0 && countChar(ta, "2") === PER
})
const after = await docText(A)
check(`A's '1's undone (got ${countChar(after, "1")})`, countChar(after, "1") === 0)
check(`B's '2's survived A's undo (got ${countChar(after, "2")})`, countChar(after, "2") === PER)
await waitFor("both browsers agree after undo", async () => (await docText(A)) === (await docText(B)))

// 5) The ActionText save: the button posts NO editor HTML — the server
// derives the rich text from the durable store via Y::Tiptap. After the
// form redirect the page shows the persisted ActionText content, and the
// editor must re-bind to the live document (a reload/late-join in passing).
await ab(A, "click", "form.button_to button, section.actiontext-save button")
await waitFor("saved ActionText content rendered after redirect", async () => {
  const saved = await ab(A, "eval", `(document.querySelector("#saved-note") || {}).textContent || ""`)
  return countChar(saved, "2") === PER && countChar(saved, "1") === 0
})
const saved = await ab(A, "eval", `document.querySelector("#saved-note").innerHTML`)
check("saved rich text holds the surviving characters", countChar(saved, "2") === PER)
check("saved rich text is server-rendered ActionText markup", /action-text|<p>/.test(saved))

// 6) A Rhino-specific mark through the render rules: Rhino's strike is its
// own "rhino-strike" mark serializing <del>; the save's mark rule must
// reproduce that. Strike everything in A, save again, and the persisted
// ActionText must carry <del> — Y::Tiptap rendering a mark the pinned
// schema has never heard of.
await ab(A, "eval", `window.__yrb.editor.chain().focus().selectAll().toggleStrike().run()`)
await waitFor("strike recorded on the shared doc", async () =>
  (await docText(A)).includes("rhino-strike"))
// No settle sleep needed: the page holds the form submit until the strike
// delta is acked (recorded server-side) — provider.hasPending drains first.
await ab(A, "click", "section.actiontext-save button")
await waitFor("saved rich text carries Rhino's <del> strike", async () => {
  const struck = await ab(A, "eval", `(document.querySelector("#saved-note") || {}).innerHTML || ""`)
  return struck.includes("<del>") && countChar(struck, "2") === PER
})
check("rhino-strike rendered as <del> via the mark rule", true)
await waitFor("editor re-synced after the save redirect", async () => /\btrue\b/.test(await synced(A)))
const reloaded = await docText(A)
check("reloaded editor still holds the live document", countChar(reloaded, "2") === PER)

console.log(failures === 0 ? "\nRHINO E2E PASS" : `\nRHINO E2E FAIL (${failures})`)
process.exit(failures === 0 ? 0 : 1)
