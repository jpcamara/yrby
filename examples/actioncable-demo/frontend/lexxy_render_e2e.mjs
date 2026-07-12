// Render-parity e2e: a real Lexxy editor (headless Chrome via agent-browser,
// against the demo's lexxy page and server) builds a document covering every
// node type, and the gem's Y::Lexxy must reproduce the editor's own `value`
// — the sanitized HTML a Lexxy form submits to Rails — from the raw doc bytes.
//
// The gem's fixture tests pin parity with the editor version they were
// captured from; this catches serializer drift when @37signals/lexxy is
// bumped. A real engine is required: Lexxy's value getter runs DOMPurify with
// custom hooks, which behaves differently under emulated DOMs (happy-dom
// silently drops heading elements).
//
//   PORT=3777 node frontend/lexxy_render_e2e.mjs   (server must be running)
import { execFile, execFileSync } from "node:child_process"
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
const ROOM = process.env.ROOM || `render-parity-${process.pid}`
const SESSION = "lexxy-render-e2e"

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ab = (...args) =>
  pexec(AB, args, { env: { ...process.env, AGENT_BROWSER_SESSION: SESSION }, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
    .then((r) => r.stdout.trim())
    .catch((e) => `${e.stdout || ""}${e.stderr || ""}`)
async function js(expr) {
  const out = await ab("eval", expr)
  if (out.startsWith("✗")) return undefined
  try { return JSON.parse(out) } catch { return out }
}
const fail = (msg) => { console.error(`lexxy render e2e FAILED: ${msg}`); process.exit(1) }

// ---------------------------------------------------------------------------
// The document: every Lexxy node type, nested.
// ---------------------------------------------------------------------------
const t = (text, format = 0) => ({ type: "text", text, format, style: "", mode: "normal", detail: 0, version: 1 })
const tab = () => ({ type: "tab", version: 1, format: 0, style: "", mode: "normal", detail: 2, text: "\t" })
const br = () => ({ type: "linebreak", version: 1 })
const elem = { direction: "ltr", format: "", indent: 0, version: 1 }
const p = (...children) => ({ type: "paragraph", ...elem, children })
const h = (tag, ...children) => ({ type: "heading", tag, ...elem, children })
const quote = (...children) => ({ type: "quote", ...elem, children })
const code = (language, ...children) => ({ type: "code", language, ...elem, children })
const link = (url, opts, ...children) => ({ type: "link", url, rel: null, target: null, title: null, ...elem, ...opts, children })
const list = (listType, tag, ...children) => ({ type: "list", listType, tag, start: 1, ...elem, children })
const li = (value, opts, ...children) => ({ type: "listitem", value, ...elem, ...opts, children })
const table = (...children) => ({ type: "table", ...elem, children })
const tr = (...children) => ({ type: "tablerow", ...elem, children })
const td = (headerState, ...children) => ({ type: "tablecell", headerState, colSpan: 1, rowSpan: 1, ...elem, children })
const B = 1, I = 2, S = 4, U = 8, C = 16, SUB = 32, SUP = 64, HL = 128

const state = { root: { type: "root", ...elem, children: [
  h("h2", t("Live ", B), link("https://spec.example.com", { title: "Spec" }, t("parity", B | I))),
  p(t("a", B), t("b", I), t("c", B | I), t("d", S), t("e", U), t("f", C), t("g", HL),
    t("h", SUB), t("i", SUP), t("j", B | I | S | U | C)),
  p({ ...t("hl-colored", HL), style: "background-color: var(--highlight-bg-2);" },
    { ...t(" bold-colored", B), style: "color: var(--highlight-fg-1);" }),
  p(t('esc: <t> & "q" ', 0), link("https://e.com?a=1&b=2", {}, t("lnk", 0))),
  quote(t("quoted ", 0), t("bold", B), br(), tab(), t("after-tab", 0)),
  list("bullet", "ul",
    li(1, {}, t("one", 0)),
    li(2, {}, t("two", 0), list("number", "ol",
      li(1, {}, t("nested ", 0), t("deep", B))))),
  list("check", "ul",
    li(1, { checked: true }, t("done", 0)),
    li(2, { checked: false }, t("todo", C))),
  code("ruby", t("def hi", 0), br(), tab(), t("42 < 43 && true", 0), br(), t("end", 0)),
  { type: "horizontal_divider", version: 1 },
  table(
    tr(td(1, p(t("H1", 0))), td(1, p(t("H2", 0)))),
    tr(td(0, p(t("a", B))), td(0, p()))),
  { type: "image_gallery", ...elem, children: [1, 2].map((n) => ({
    type: "action_text_attachment", version: 1, tagName: "action-text-attachment",
    sgid: `SGID_G${n}`, src: `${BASE}/files/g${n}.png`, previewable: true,
    altText: `G${n}`, caption: null, contentType: "image/png",
    fileName: `g${n}.png`, fileSize: n, width: 100, height: 80,
  })) },
  p(t("tail 🚀 你好", 0)),
  p(),
] } }

// ---------------------------------------------------------------------------
// Drive the page: open, wait for sync, inject the state, read both sides.
// ---------------------------------------------------------------------------
await ab("open", `${BASE}/docs/${ROOM}/lexxy`)
let synced = false
for (let i = 0; i < 60 && !synced; i++) {
  synced = (await js("window.__yrb && window.__yrb.provider.synced === true")) === true
  if (!synced) await sleep(500)
}
if (!synced) fail("page never synced (is the server running?)")

const injected = await js(`(() => {
  const ed = document.getElementById("editor").editor
  try { ed.setEditorState(ed.parseEditorState(${JSON.stringify(JSON.stringify(state))})); return "ok" }
  catch (e) { return "ERROR: " + e.message }
})()`)
if (injected !== "ok") fail(`state injection: ${injected}`)
await sleep(1500) // let the collab binding + provider settle

const editorHtml = await js('document.getElementById("editor").value')
const stateB64 = await js("window.__yrb.encodeState()")

if (typeof editorHtml !== "string" || typeof stateB64 !== "string") {
  fail(`could not read editor value/state (value: ${typeof editorHtml}, state: ${typeof stateB64})`)
}
for (const [what, marker] of [["heading", "<h2>"], ["table", "</table>"], ["code block", "<pre"], ["checklist", "aria-checked"], ["divider", "<hr>"], ["gallery", 'class="attachment-gallery attachment-gallery--2"']]) {
  if (!editorHtml.includes(marker)) fail(`editor value is missing ${what} (${marker}); head: ${editorHtml.slice(0, 200)}`)
}

const actual = execFileSync("bundle", ["exec", "ruby", "frontend/render_check.rb", "lexical", "root"], {
  input: Buffer.from(stateB64, "base64"),
  maxBuffer: 64 * 1024 * 1024,
}).toString()

if (actual === editorHtml) {
  // The lexxy page materializes the "root" fragment to ActionText on read
  // (see NoteMaterializer): fetching the page must show the document we
  // just built. Assert on tag markers only — ActionText's display
  // sanitizer strips class/aria attributes, and this synthetic state's
  // attachment sgids resolve to missing-attachment placeholders. The
  // capture runs to </section> because Lexxy content nests divs.
  const page = await fetch(`${BASE}/docs/${ROOM}/lexxy`).then((r) => r.text())
  const m = page.match(/<div id="saved-note"[^>]*>([\s\S]*?)<\/section>/)
  const saved = m ? m[1] : ""
  for (const marker of ["<h2>", "<hr>", "<pre"]) {
    if (!saved.includes(marker)) fail(`materialized note is missing ${marker}; head: ${saved.slice(0, 200)}`)
  }
  console.log("lexxy materialized note OK: a page read rendered the root fragment to ActionText")
  console.log(`lexxy render e2e OK: Y::Lexxy matches a live Lexxy value (${actual.length} chars)`)
  process.exit(0)
}
let i = 0
while (i < Math.min(actual.length, editorHtml.length) && actual[i] === editorHtml[i]) i++
console.error("lexxy render e2e MISMATCH: Y::Lexxy diverges from the live editor")
console.error(`first difference at ${i}:`)
console.error(`  editor: …${JSON.stringify(editorHtml.slice(Math.max(0, i - 60), i + 80))}`)
console.error(`  ruby:   …${JSON.stringify(actual.slice(Math.max(0, i - 60), i + 80))}`)
process.exit(1)
