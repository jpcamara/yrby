// Render-parity e2e: a real Tiptap editor runs headless (JSDOM), builds a
// document over the y-prosemirror collab binding, and the gem's Y::ProseMirror
// must reproduce the editor's own getHTML() from the raw doc bytes.
//
// This is the live version of the captured-fixture tests in the gem: the
// fixtures pin parity with the editor version they were captured from; this
// catches serializer drift when @tiptap/* is bumped.
//
//   node frontend/render_e2e.mjs   (from examples/actioncable-demo)
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!DOCTYPE html><body></body>", { pretendToBeVisual: true })
global.window = dom.window
global.document = dom.window.document
for (const key of ["Node", "Element", "DOMParser", "MutationObserver", "getComputedStyle", "HTMLElement", "Text", "DocumentFragment", "ClipboardEvent"]) {
  if (dom.window[key] !== undefined && global[key] === undefined) global[key] = dom.window[key]
}

const Y = await import("yjs")
const { Editor } = await import("@tiptap/core")
const { default: StarterKit } = await import("@tiptap/starter-kit")
const { default: Collaboration } = await import("@tiptap/extension-collaboration")
const { default: Link } = await import("@tiptap/extension-link")
const { default: Underline } = await import("@tiptap/extension-underline")
const { default: Highlight } = await import("@tiptap/extension-highlight")
const { default: Subscript } = await import("@tiptap/extension-subscript")
const { default: Superscript } = await import("@tiptap/extension-superscript")
const { default: Image } = await import("@tiptap/extension-image")
const { default: Table } = await import("@tiptap/extension-table")
const { default: TableRow } = await import("@tiptap/extension-table-row")
const { default: TableCell } = await import("@tiptap/extension-table-cell")
const { default: TableHeader } = await import("@tiptap/extension-table-header")
const { default: TaskList } = await import("@tiptap/extension-task-list")
const { default: TaskItem } = await import("@tiptap/extension-task-item")
const { default: TextStyle } = await import("@tiptap/extension-text-style")
const { default: Color } = await import("@tiptap/extension-color")
const { default: Mention } = await import("@tiptap/extension-mention")
const { execFileSync } = await import("node:child_process")

const ydoc = new Y.Doc()
const el = document.createElement("div")
document.body.appendChild(el)
const editor = new Editor({
  element: el,
  extensions: [
    StarterKit.configure({ history: false }),
    Collaboration.configure({ document: ydoc }),
    Link.configure({ openOnClick: false }),
    Underline, Highlight, Subscript, Superscript, Image,
    Table, TableRow, TableCell, TableHeader, TaskList, TaskItem,
    TextStyle, Color, Mention,
  ],
})

// Every node and mark the renderer covers, in one document.
editor.commands.setContent(
  "<h1>Live parity</h1><h3>Sub</h3>" +
  '<p>plain <strong>b</strong> <em>i</em> <strong><em>bi</em></strong> <s>st</s> <u>u</u> <code>c</code> <mark>hl</mark> x<sub>1</sub>y<sup>2</sup> <a href="https://e.com?a=1&amp;b=2" target="_blank">link</a></p>' +
  '<p>esc: &lt;tag &amp; "q"&gt;</p>' +
  "<blockquote><p>quote</p></blockquote>" +
  "<ul><li><p>one</p><ul><li><p>nested</p></li></ul></li><li><p>two</p></li></ul>" +
  '<ol start="4"><li><p>four</p></li></ol>' +
  '<ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>done</p></li><li data-type="taskItem" data-checked="false"><p>todo</p></li></ul>' +
  '<pre><code class="language-js">const x = 1;\nrun();</code></pre>' +
  "<pre><code>plain</code></pre>" +
  "<p>a<br>b</p><hr>" +
  '<img src="https://e.com/p.png" alt="alt" title="t">'
)
// Inline nodes and marks that need commands rather than HTML input.
editor.commands.insertContent([
  { type: "paragraph", content: [
    { text: "Hi ", type: "text" },
    { type: "mention", attrs: { id: "u1", label: "Alice" } },
    { text: " ", type: "text" },
    { text: "colored", type: "text", marks: [{ type: "textStyle", attrs: { color: "#ff0000" } }] },
  ] },
  { type: "table", content: [
    { type: "tableRow", content: [
      { type: "tableHeader", content: [{ type: "paragraph", content: [{ type: "text", text: "H" }] }] },
      { type: "tableCell", content: [{ type: "paragraph", content: [{ type: "text", text: "C" }] }] },
    ] },
  ] },
])

const editorHtml = editor.getHTML()

// The one intended divergence: Y::ProseMirror renders tables semantically
// (like tiptap-php), without the <colgroup>/min-width sizing Tiptap's editor
// VIEW injects into getHTML (it isn't in the CRDT). Strip it from the
// editor's output; everything else must match byte for byte.
const expected = editorHtml
  .replaceAll(/<table style="min-width: [^"]*">/g, "<table>")
  .replaceAll(/<colgroup>.*?<\/colgroup>/g, "")

const update = Buffer.from(Y.encodeStateAsUpdate(ydoc))
const actual = execFileSync("bundle", ["exec", "ruby", "frontend/render_check.rb", "default"], {
  input: update,
  maxBuffer: 64 * 1024 * 1024,
}).toString()

if (actual === expected) {
  console.log(`render e2e OK: Y::ProseMirror matches a live Tiptap getHTML() (${actual.length} chars)`)
  process.exit(0)
}
let i = 0
while (i < Math.min(actual.length, expected.length) && actual[i] === expected[i]) i++
console.error("render e2e MISMATCH: Y::ProseMirror diverges from the live editor")
console.error(`first difference at ${i}:`)
console.error(`  editor: …${JSON.stringify(expected.slice(Math.max(0, i - 60), i + 80))}`)
console.error(`  ruby:   …${JSON.stringify(actual.slice(Math.max(0, i - 60), i + 80))}`)
process.exit(1)
