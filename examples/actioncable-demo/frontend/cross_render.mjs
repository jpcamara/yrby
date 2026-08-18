// Cross-renderer verification: the gem's renderers against independent,
// prominent HTML sources for the same documents.
//
// ProseMirror side, per corpus document:
//   - a live headless Tiptap editor's getHTML()      (must match byte-for-byte)
//   - @tiptap/html's static generateHTML()           (compared DOM-normalized)
//   - tiptap-php via docker, when available          (compared DOM-normalized)
// Lexical side, per corpus document:
//   - @lexical/html's $generateHtmlFromNodes on a headless editor
//     (compared DOM-normalized against Y::Lexical)
//
// Byte parity is the gem's contract with the editor it pins. The
// independent sources legitimately differ in spots (escaping style,
// editor-view attributes), so those comparisons are DOM-normalized and
// every remaining difference is printed for triage.
//
//   node frontend/cross_render.mjs   (from examples/actioncable-demo)
import { JSDOM } from "jsdom"

const dom = new JSDOM("<!DOCTYPE html><body></body>", { pretendToBeVisual: true })
global.window = dom.window
global.document = dom.window.document
for (const key of ["Node", "Element", "DOMParser", "MutationObserver", "getComputedStyle", "HTMLElement", "Text", "DocumentFragment", "ClipboardEvent", "CustomEvent"]) {
  if (dom.window[key] !== undefined && global[key] === undefined) global[key] = dom.window[key]
}

const Y = await import("yjs")
const { execFileSync, spawnSync } = await import("node:child_process")

let failures = 0
let diffs = 0
const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`)
  if (!ok) failures++
}

// DOM-normalized form: parse, then serialize with sorted attributes and
// collapsed whitespace outside pre/code, so cosmetic differences (attribute
// order, escaping style, insignificant whitespace) don't count as diffs.
function normalize(html) {
  const frag = JSDOM.fragment(`<div id="__root">${html}</div>`)
  const walk = (node, inPre) => {
    if (node.nodeType === 3) {
      const text = inPre ? node.textContent : node.textContent.replace(/\s+/g, " ")
      return text === " " ? "" : text
    }
    if (node.nodeType !== 1) return ""
    const tag = node.tagName.toLowerCase()
    const pre = inPre || tag === "pre" || tag === "code"
    const attrs = [...node.attributes]
      .map((a) => `${a.name}="${a.value}"`)
      .sort()
      .join(" ")
    const children = [...node.childNodes].map((c) => walk(c, pre)).join("")
    return `<${tag}${attrs ? " " + attrs : ""}>${children}</${tag}>`
  }
  return [...frag.firstChild.childNodes].map((c) => walk(c, false)).join("")
}

// The live editor decorates tables with view chrome the gem deliberately
// omits (README: "without the column-width styling Tiptap's editor view
// adds"): a colgroup skeleton and min-width styles. Strip exactly that
// from the editor's output before comparing, so anything else still fails.
function stripEditorTableChrome(html) {
  return html
    .replace(/<colgroup>.*?<\/colgroup>/g, "")
    .replace(/ style="min-width: [^"]*"/g, "")
}

// Stock Lexical's $generateHtmlFromNodes wraps every text run in
// <span style="white-space: pre-wrap;"> and doubles bold as <b><strong>.
// Those are its export idioms, not structure; unwrap them so real
// structural differences still surface.
function stripLexicalIdioms(html) {
  const frag = JSDOM.fragment(`<div id="__root">${html}</div>`)
  const root = frag.firstChild
  for (const span of [...root.querySelectorAll("span")]) {
    if (span.attributes.length === 1 && span.getAttribute("style") === "white-space: pre-wrap;") {
      span.replaceWith(...span.childNodes)
    }
  }
  for (const b of [...root.querySelectorAll("b")]) {
    if (b.attributes.length === 0 && b.childNodes.length === 1 && b.firstChild.tagName === "STRONG") {
      b.replaceWith(b.firstChild)
    }
  }
  for (const i of [...root.querySelectorAll("i")]) {
    if (i.attributes.length === 0 && i.childNodes.length === 1 && i.firstChild.tagName === "EM") {
      i.replaceWith(i.firstChild)
    }
  }
  for (const el of [...root.querySelectorAll("[spellcheck]")]) {
    el.removeAttribute("spellcheck")
  }
  for (const el of [...root.querySelectorAll("[style]")]) {
    const style = el.getAttribute("style").replace(/white-space: pre-wrap;?\s*/, "").trim()
    if (style === "") el.removeAttribute("style")
    else el.setAttribute("style", style)
  }
  for (const span of [...root.querySelectorAll("span")]) {
    if (span.attributes.length === 0) span.replaceWith(...span.childNodes)
  }
  return root.innerHTML
}

// tiptap-php spells two things differently from Tiptap's own serializer
// (which we match byte-for-byte): strike renders <strike> instead of <s>,
// and an ordered list carries an explicit start="1". Translate those
// spellings before comparing so anything else still fails.
function translatePhpSpellings(html) {
  return html
    .replace(/<(\/?)strike>/g, "<$1s>")
    .replace(/<ol start="1">/g, "<ol>")
}

// tiptap-php drops textStyle attributes (the color the live editor keeps),
// so that case is a known quirk rather than a comparison.
const KNOWN_PHP_QUIRKS = {
  "colored text": "tiptap-php drops textStyle attributes (the color)",
}

// Divergences from @tiptap/html's static renderer that are its own quirks,
// verified against the live editor (which we match byte-for-byte):
//   - it drops the Color extension's textStyle color
//   - it serializes a true data-checked as data-checked=""
const KNOWN_STATIC_QUIRKS = {
  "colored text": "static generateHTML drops the textStyle color the live editor renders",
  "task list": 'static generateHTML writes data-checked="" for a checked item',
}

function compareNormalized(label, ours, theirs) {
  if (normalize(ours) === normalize(theirs)) {
    console.log(`ok: ${label} (DOM-equal)`)
    return
  }
  diffs++
  console.log(`DIFF: ${label}`)
  const a = normalize(ours)
  const b = normalize(theirs)
  let i = 0
  while (i < Math.min(a.length, b.length) && a[i] === b[i]) i++
  console.log(`  ours:   …${a.slice(Math.max(0, i - 40), i + 80)}…`)
  console.log(`  theirs: …${b.slice(Math.max(0, i - 40), i + 80)}…`)
}

function renderOurs(kind, root, update) {
  return execFileSync("bundle", ["exec", "ruby", "frontend/render_check.rb", kind, root], {
    input: Buffer.from(update),
    maxBuffer: 64 * 1024 * 1024,
  }).toString()
}

// --- ProseMirror / Tiptap ---------------------------------------------------

const { Editor } = await import("@tiptap/core")
const { generateHTML } = await import("@tiptap/html")
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

const tiptapStatic = [
  StarterKit.configure({ history: false }),
  Link.configure({ openOnClick: false }),
  Underline, Highlight, Subscript, Superscript, Image,
  Table, TableRow, TableCell, TableHeader, TaskList, TaskItem,
  TextStyle, Color,
]

const PM_CORPUS = {
  "headings and paragraphs": `<h1>Title</h1><h2>Sub</h2><p>Body text.</p><p>Another paragraph.</p>`,
  "mark matrix": `<p><strong>bold</strong> <em>italic</em> <s>strike</s> <u>under</u> <code>code</code> <a href="https://example.com">link</a> <mark>marked</mark> <sub>sub</sub> <sup>sup</sup> <strong><em>nested <u>deep</u></em></strong></p>`,
  "colored text": `<p><span style="color: #958DF1">violet</span> plain</p>`,
  "nested lists": `<ul><li><p>one</p><ul><li><p>one.one</p></li></ul></li><li><p>two</p></li></ul><ol><li><p>first</p></li><li><p>second</p></li></ol>`,
  "task list": `<ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>done</p></li><li data-type="taskItem" data-checked="false"><p>todo</p></li></ul>`,
  "quote rule break": `<blockquote><p>quoted</p></blockquote><hr><p>after<br>break</p>`,
  "code block": `<pre><code class="language-ruby">def hi\n  "&lt;there&gt;"\nend</code></pre>`,
  "table": `<table><tbody><tr><th><p>h1</p></th><th><p>h2</p></th></tr><tr><td><p>a</p></td><td><p>b &amp; c</p></td></tr></tbody></table>`,
  "image": `<p>before</p><img src="https://example.com/pic.png" alt="a pic" title="pic">`,
}

const phpAvailable = spawnSync("docker", ["--version"], { stdio: "ignore" }).status === 0
let phpWarmed = false
function tiptapPhp(json) {
  const script = `
    require '/opt/vendor/autoload.php';
    $doc = json_decode(file_get_contents('php://stdin'), true);
    $editor = new \\Tiptap\\Editor(['extensions' => [
      new \\Tiptap\\Extensions\\StarterKit(),
      new \\Tiptap\\Marks\\Link(),
      new \\Tiptap\\Marks\\Underline(),
      new \\Tiptap\\Marks\\Highlight(),
      new \\Tiptap\\Marks\\Subscript(),
      new \\Tiptap\\Marks\\Superscript(),
      new \\Tiptap\\Marks\\TextStyle(),
      new \\Tiptap\\Nodes\\Table(),
      new \\Tiptap\\Nodes\\TableRow(),
      new \\Tiptap\\Nodes\\TableCell(),
      new \\Tiptap\\Nodes\\TableHeader(),
      new \\Tiptap\\Nodes\\TaskList(),
      new \\Tiptap\\Nodes\\TaskItem(),
      new \\Tiptap\\Nodes\\Image(),
    ]]);
    echo $editor->setContent($doc)->getHTML();
  `
  const run = spawnSync("docker", [
    "run", "--rm", "-i", "-v", "cross-render-php:/opt", "php:8.4-cli", "php", "-r", script,
  ], { input: JSON.stringify(json), encoding: "utf8", maxBuffer: 16 * 1024 * 1024 })
  if (run.status !== 0) throw new Error(run.stderr.slice(0, 400))
  return run.stdout
}

function warmPhp() {
  // One-time: composer-install tiptap-php into a named volume.
  const r = spawnSync("docker", [
    "run", "--rm", "-v", "cross-render-php:/opt", "-w", "/opt", "composer:2",
    "composer", "require", "--quiet", "ueberdosis/tiptap-php:^1.4",
  ], { encoding: "utf8", timeout: 300000 })
  return r.status === 0
}

console.log("\n=== ProseMirror: Y::Tiptap vs the ecosystem ===")
if (phpAvailable) phpWarmed = warmPhp()
if (!phpWarmed) console.log("note: tiptap-php leg skipped (docker or composer install unavailable)")

for (const [name, html] of Object.entries(PM_CORPUS)) {
  const ydoc = new Y.Doc()
  const el = document.createElement("div")
  document.body.appendChild(el)
  const editor = new Editor({
    element: el,
    extensions: [Collaboration.configure({ document: ydoc }), ...tiptapStatic],
  })
  // Content must be set after creation: the collab binding syncs commands,
  // not the constructor's initial content.
  editor.commands.setContent(html)
  const editorHtml = editor.getHTML()
  const json = editor.getJSON()
  const update = Y.encodeStateAsUpdate(ydoc)
  const ours = renderOurs("prosemirror", "default", update)

  if (name === "table") {
    check(
      `${name}: byte parity with the live editor (minus documented table view chrome)`,
      ours === stripEditorTableChrome(editorHtml)
    )
  } else {
    check(`${name}: byte parity with the live editor`, ours === editorHtml)
  }
  if (KNOWN_STATIC_QUIRKS[name]) {
    console.log(`ok: ${name}: vs @tiptap/html generateHTML (known quirk: ${KNOWN_STATIC_QUIRKS[name]})`)
  } else {
    compareNormalized(`${name}: vs @tiptap/html generateHTML`, ours, stripEditorTableChrome(generateHTML(json, tiptapStatic)))
  }
  if (phpWarmed) {
    if (KNOWN_PHP_QUIRKS[name]) {
      console.log(`ok: ${name}: vs tiptap-php (known quirk: ${KNOWN_PHP_QUIRKS[name]})`)
    } else {
      try {
        compareNormalized(`${name}: vs tiptap-php`, ours, translatePhpSpellings(tiptapPhp(json)))
      } catch (e) {
        console.log(`note: ${name}: tiptap-php run failed (${String(e).slice(0, 120)})`)
      }
    }
  }
  editor.destroy()
  el.remove()
}

// --- Lexical ----------------------------------------------------------------

const { createHeadlessEditor } = await import("@lexical/headless")
const { $generateHtmlFromNodes } = await import("@lexical/html")
const lexical = await import("lexical")
const { HeadingNode, QuoteNode, $createHeadingNode, $createQuoteNode } = await import("@lexical/rich-text")
const { ListNode, ListItemNode, $createListNode, $createListItemNode } = await import("@lexical/list")
const { LinkNode, $createLinkNode } = await import("@lexical/link")
const { CodeNode, $createCodeNode } = await import("@lexical/code")
const { createBinding, syncLexicalUpdateToYjs, syncYjsChangesToLexical } = await import("@lexical/yjs")

const {
  $getRoot, $createParagraphNode, $createTextNode, $createLineBreakNode,
  HORIZONTAL_RULE_TAG: _unused,
} = lexical

const LEXICAL_CORPUS = {
  "headings and paragraphs": () => {
    const root = $getRoot()
    const h = $createHeadingNode("h1")
    h.append($createTextNode("Title"))
    const h2 = $createHeadingNode("h2")
    h2.append($createTextNode("Sub"))
    const p = $createParagraphNode()
    p.append($createTextNode("Body text."))
    root.append(h, h2, p)
  },
  "format matrix": () => {
    const root = $getRoot()
    const p = $createParagraphNode()
    const mk = (text, ...formats) => {
      const t = $createTextNode(text)
      formats.forEach((f) => t.toggleFormat(f))
      return t
    }
    p.append(
      mk("bold", "bold"), $createTextNode(" "),
      mk("italic", "italic"), $createTextNode(" "),
      mk("strike", "strikethrough"), $createTextNode(" "),
      mk("under", "underline"), $createTextNode(" "),
      mk("code", "code"), $createTextNode(" "),
      mk("bolditalic", "bold", "italic"),
    )
    const link = $createLinkNode("https://example.com")
    link.append($createTextNode("link"))
    p.append($createTextNode(" "), link)
    root.append(p)
  },
  "lists": () => {
    const root = $getRoot()
    const ul = $createListNode("bullet")
    const li1 = $createListItemNode()
    li1.append($createTextNode("one"))
    const li2 = $createListItemNode()
    li2.append($createTextNode("two"))
    ul.append(li1, li2)
    const ol = $createListNode("number")
    const oli = $createListItemNode()
    oli.append($createTextNode("first"))
    ol.append(oli)
    root.append(ul, ol)
  },
  "quote and code": () => {
    const root = $getRoot()
    const q = $createQuoteNode()
    q.append($createTextNode("quoted"))
    const c = $createCodeNode("ruby")
    c.append($createTextNode('def hi'), $createLineBreakNode(), $createTextNode('  "<there>"'), $createLineBreakNode(), $createTextNode("end"))
    root.append(q, c)
  },
}

console.log("\n=== Lexical: Y::Lexical vs @lexical/html ===")

const lexicalNodes = [HeadingNode, QuoteNode, ListNode, ListItemNode, LinkNode, CodeNode]
for (const [name, build] of Object.entries(LEXICAL_CORPUS)) {
  const editor = createHeadlessEditor({ nodes: lexicalNodes, theme: {}, onError: (e) => { throw e } })
  const ydoc = new Y.Doc()
  const provider = { awareness: { setLocalState() {}, getLocalState: () => null, getStates: () => new Map(), on() {}, off() {} } }
  const docMap = new Map([["root", ydoc]])
  const binding = createBinding(editor, provider, "root", ydoc, docMap)

  const removeListener = editor.registerUpdateListener(
    ({ dirtyElements, dirtyLeaves, editorState, normalizedNodes, prevEditorState, tags }) => {
      editor.getEditorState().read(() => {
        syncLexicalUpdateToYjs(binding, provider, prevEditorState, editorState, dirtyElements, dirtyLeaves, normalizedNodes, tags)
      })
    }
  )
  const observer = (events, transaction) => {
    if (transaction.origin !== binding) syncYjsChangesToLexical(binding, provider, events, false)
  }
  binding.root.getSharedType().observeDeep(observer)

  editor.update(build, { discrete: true })

  const update = Y.encodeStateAsUpdate(ydoc)
  const ours = renderOurs("lexical-core", "root", update)
  let reference = ""
  editor.getEditorState().read(() => {
    reference = $generateHtmlFromNodes(editor)
  })
  compareNormalized(`${name}: vs $generateHtmlFromNodes (idioms stripped)`, ours, stripLexicalIdioms(reference))

  removeListener()
  binding.root.getSharedType().unobserveDeep(observer)
}

console.log(`\n${failures} byte-parity failure(s), ${diffs} cross-source difference(s) for triage`)
process.exit(failures > 0 ? 1 : 0)
