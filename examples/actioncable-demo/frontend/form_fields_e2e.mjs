// Two-window e2e for the yrby-forms page (/tickets/:id): <yrby-document> and
// the packaged <collaborative-field> over a real Rails form,
// Y::Forms::FieldsChannel, and Y::Document storage. Asserts the LWW fields
// converge (last write wins), the text field merges concurrent typing,
// presence shows on the peer, and the ticket's columns match what the clients
// converged on.
//
//   SERVER=puma PORT=3777 frontend/boot_server.sh   # or any booted demo server
//   PORT=3777 node frontend/form_fields_e2e.mjs
import { execFileSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const BASE = process.env.BASE || `http://127.0.0.1:${process.env.PORT || 9600}`
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const TAG = `${Date.now()}`.slice(-6)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ab = (s, ...a) => { try { return execFileSync(AB, a, { env: { ...process.env, AGENT_BROWSER_SESSION: s }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) } catch (e) { return `${e.stdout || ""}${e.stderr || ""}` } }
async function waitEval(s, js, label, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (/\btrue\b/.test(ab(s, "eval", js))) return true; await sleep(300) } console.log(`  TIMEOUT: ${label} (${s})`); return false }
let failures = 0; const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }

const synced = (s) => waitEval(s, "document.querySelector('yrby-document')?.current !== undefined", "synced")
const setValue = (s, selector, value) =>
  ab(s, "eval", `(() => { const e = document.querySelector('${selector}'); e.value = ${JSON.stringify(value)}; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true })); })()`)

console.log(`# yrby-forms (${BASE}/tickets/${TAG})`)
ab("ff-a", "open", `${BASE}/tickets/${TAG}`); ab("ff-b", "open", `${BASE}/tickets/${TAG}`)
check("a synced", await synced("ff-a")); check("b synced", await synced("ff-b"))

// LWW: converge, and the later write wins.
setValue("ff-a", "select", "active")
check("b sees a's status", await waitEval("ff-b", "document.querySelector('select').value === 'active'", "lww sync"))
setValue("ff-b", "select", "done")
check("a sees b's later status (last write wins)", await waitEval("ff-a", "document.querySelector('select').value === 'done'", "lww last write"))

// A checkbox. Rails renders a hidden input before it, and the field binds the
// checkbox.
const URGENT = "collaborative-field[name=urgent] input[type=checkbox]"
ab("ff-a", "click", URGENT)
check("b sees a's checkbox", await waitEval("ff-b", `document.querySelector('${URGENT}').checked === true`, "checkbox sync"))

// Text: concurrent typing in the description merges (both edits survive).
const DESC = "collaborative-field[name=description] textarea"
setValue("ff-a", DESC, "It fails on Tuesdays.")
check("b sees a's description", await waitEval("ff-b", `document.querySelector('${DESC}').value === 'It fails on Tuesdays.'`, "text sync"))
// Concurrent edits, each relative to whatever the window currently shows so
// neither depends on winning the race: a appends, b prepends.
ab("ff-a", "eval", `(() => { const e = document.querySelector('${DESC}'); e.value = e.value + ' A${TAG}'; e.dispatchEvent(new Event('input', { bubbles: true })); })()`)
ab("ff-b", "eval", `(() => { const e = document.querySelector('${DESC}'); e.value = 'B${TAG} ' + e.value; e.dispatchEvent(new Event('input', { bubbles: true })); })()`)
const mergedJs = `(() => { const v = document.querySelector('${DESC}').value; return v.includes('A${TAG}') && v.includes('B${TAG}') && v.includes('It fails on Tuesdays.'); })()`
check("a holds both concurrent edits", await waitEval("ff-a", mergedJs, "text merge a"))
check("b holds both concurrent edits", await waitEval("ff-b", mergedJs, "text merge b"))

// A second field, so materialization covers a text-tier input too.
setValue("ff-a", "collaborative-field[name=summary] input", `Fix the flaky spec ${TAG}`)

// Presence: a focuses the description; b shows the outline and name chip.
ab("ff-a", "click", DESC)
check("a announces the focused field", await waitEval("ff-a", "document.querySelector('yrby-document').provider.awareness.getLocalState()?.field === 'description'", "presence local"))
check("b outlines the field a is in", await waitEval("ff-b", "document.querySelector('collaborative-field[name=description]').hasAttribute('data-remote')", "presence outline"))
check("b shows a's name chip", await waitEval("ff-b", "(document.querySelector('collaborative-field[name=description] .collaborative-field-chip')?.textContent || '').length > 0", "presence chip"))

// The channel writes the columns after every change. Poll until they hold
// the merge, then check that both clients show the description column's text.
// a == column == b proves convergence without parsing strings out of the
// browser sessions.
let state = {}
for (let i = 0; i < 30; i++) {
  state = await (await fetch(`${BASE}/tickets/${TAG}/state`)).json()
  if (state.status === "done" && `${state.description}`.includes(`A${TAG}`) &&
      `${state.description}`.includes(`B${TAG}`) && state.summary) break
  await sleep(400)
}
check("the status column is the last write", state.status === "done")
check("the urgent column is true", state.urgent === true)
check("the summary column matches", state.summary === `Fix the flaky spec ${TAG}`)
const descJs = JSON.stringify(state.description ?? "")
check("a's text equals the description column", await waitEval("ff-a", `document.querySelector('${DESC}').value === ${descJs}`, "column == a"))
check("b's text equals the description column", await waitEval("ff-b", `document.querySelector('${DESC}').value === ${descJs}`, "column == b"))

ab("ff-a", "close"); ab("ff-b", "close")

console.log(""); if (failures) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: yrby-forms e2e (${TAG})`); process.exit(0)
