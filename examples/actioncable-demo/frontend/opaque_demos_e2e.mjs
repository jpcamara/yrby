// Two-window collaboration e2e for the four "opaque state" demo pages
// (CodeMirror / whiteboard / kanban / forms). Each asserts on the shared Yjs
// type exposed at window.__yrb, so it's robust to DOM details.
//
//   PORT=9600 STORE_KIND=file bundle exec puma -p 9600 config.ru   # server
//   node opaque_demos_e2e.mjs
import { execFileSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const BASE = process.env.BASE || "http://127.0.0.1:9600"
const AB = process.env.AB_BIN || resolve(here, "node_modules/.bin/agent-browser")
const TAG = `${Date.now()}`.slice(-6)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ab = (s, ...a) => { try { return execFileSync(AB, a, { env: { ...process.env, AGENT_BROWSER_SESSION: s }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }) } catch (e) { return `${e.stdout || ""}${e.stderr || ""}` } }
async function waitEval(s, js, label, ms = 15000) { const end = Date.now() + ms; while (Date.now() < end) { if (/\btrue\b/.test(ab(s, "eval", js))) return true; await sleep(300) } console.log(`  TIMEOUT: ${label} (${s})`); return false }
let failures = 0; const check = (l, ok) => { console.log(`${ok ? "ok" : "FAIL"}: ${l}`); if (!ok) failures++ }
const synced = (s) => waitEval(s, "!!window.__yrb?.provider?.synced", "synced")

// --- CodeMirror (Y.Text) ----------------------------------------------------
console.log("# codemirror")
ab("cm-a", "open", `${BASE}/docs/demo-${TAG}/codemirror`); ab("cm-b", "open", `${BASE}/docs/demo-${TAG}/codemirror`)
check("a synced", await synced("cm-a")); check("b synced", await synced("cm-b"))
ab("cm-a", "click", ".cm-content"); ab("cm-a", "keyboard", "type", `X${TAG}`)
check("b sees a's code", await waitEval("cm-b", `window.__yrb.ytext.toString().includes("X${TAG}")`, "cm sync"))
ab("cm-a", "close"); ab("cm-b", "close")

// --- Whiteboard (Y.Map of shapes) -------------------------------------------
console.log("\n# whiteboard")
ab("wb-a", "open", `${BASE}/docs/demo-${TAG}/whiteboard`); ab("wb-b", "open", `${BASE}/docs/demo-${TAG}/whiteboard`)
check("a synced", await synced("wb-a")); check("b synced", await synced("wb-b"))
ab("wb-a", "eval", `(() => { const c=document.getElementById('canvas'); const r=c.getBoundingClientRect(); c.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,clientX:r.left+150,clientY:r.top+150})); })()`)
check("b sees a new shape", await waitEval("wb-b", "window.__yrb.shapes.size >= 3", "wb add"))
ab("wb-a", "eval", `(() => { const ids=[...window.__yrb.shapes.keys()]; const m=window.__yrb.shapes.get(ids[ids.length-1]); m.doc.transact(()=>{m.set('x',777);m.set('y',555);}); })()`)
check("b sees the move", await waitEval("wb-b", "[...window.__yrb.shapes.values()].some(m=>m.get('x')===777&&m.get('y')===555)", "wb move"))
ab("wb-a", "close"); ab("wb-b", "close")

// --- Kanban (Y.Array of Y.Map) ----------------------------------------------
console.log("\n# kanban")
ab("kb-a", "open", `${BASE}/docs/demo-${TAG}/kanban`); ab("kb-b", "open", `${BASE}/docs/demo-${TAG}/kanban`)
check("a synced", await synced("kb-a")); check("b synced", await synced("kb-b"))
ab("kb-a", "eval", `(() => { const i=document.querySelector('.col .add input'); i.value="C${TAG}"; i.closest('form').requestSubmit(); })()`)
check("b sees a's card", await waitEval("kb-b", `window.__yrb.cards.toArray().some(m=>m.get('text')==="C${TAG}")`, "kb add"))
ab("kb-a", "eval", `(() => { const m=window.__yrb.cards.toArray().find(m=>m.get('text')==="C${TAG}"); m.set('column','doing'); })()`)
check("b sees the card move", await waitEval("kb-b", `window.__yrb.cards.toArray().find(m=>m.get('text')==="C${TAG}")?.get('column')==='doing'`, "kb move"))
ab("kb-a", "close"); ab("kb-b", "close")

// --- Forms (Y.Map) ----------------------------------------------------------
console.log("\n# forms")
ab("fm-a", "open", `${BASE}/docs/demo-${TAG}/forms`); ab("fm-b", "open", `${BASE}/docs/demo-${TAG}/forms`)
check("a synced", await synced("fm-a")); check("b synced", await synced("fm-b"))
ab("fm-a", "eval", `(() => { const e=document.querySelector('[data-key=name]'); e.value="Ada${TAG}"; e.dispatchEvent(new Event('input',{bubbles:true})); })()`)
check("b sees a's field", await waitEval("fm-b", `window.__yrb.form.get('name')==="Ada${TAG}"`, "fm sync"))
check("b's input reflects it", await waitEval("fm-b", `document.querySelector('[data-key=name]').value==="Ada${TAG}"`, "fm input"))
ab("fm-a", "close"); ab("fm-b", "close")

console.log(""); if (failures) { console.log(`FAILED: ${failures}`); process.exit(1) }
console.log(`PASS: opaque-state demos e2e (${TAG})`); process.exit(0)
