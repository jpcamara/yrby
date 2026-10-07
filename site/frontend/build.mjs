// Bundles the demo pages into ../public, one file per entry.
//
// Every entry shares one copy of yjs and the other CRDT singletons. yrby-client
// declares yjs and y-protocols as optional *peer* dependencies and depends on
// lib0 directly, so a package manager can install a second copy of any of them
// under yrby-client. Then the provider's `import "yjs"` resolves to the nested
// copy while the editor (y-prosemirror, y-codemirror.next) uses the top-level
// one, and the bundle has two Y.js instances. That trips Yjs's "already
// imported" guard and breaks constructor checks. y-prosemirror throws "Method
// unimplemented" when it applies remote updates, so the editor never shows
// incoming content, and the next local keystroke overwrites it. Nothing about
// the failure points at module resolution, so the build always pins these
// packages, even when there's only one copy installed.
//
//   bun build.mjs            # one-shot build
//   bun build.mjs --watch    # rebuild on change
/* global Bun */
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))

// Each shared singleton resolves to the copy in the top-level node_modules, so
// every importer gets the same one. `lexical` and `@lexical/yjs` are here for
// the Lexxy page. Two copies of `lexical` break Lexical's node-class identity,
// the same way two copies of yjs break constructor checks: the binding throws on
// remote updates, and nothing about the symptom points at module resolution.
// @37signals/lexxy and lexxy-realtime both list them as peers so the app can
// pin one copy.
const SINGLETONS = ["yjs", "y-protocols", "lib0", "lexical", "@lexical/yjs"]
const canonical = (name) => resolve(here, "node_modules", name)

const dedupeSingletons = {
  name: "dedupe-singletons",
  setup(build) {
    for (const name of SINGLETONS) {
      // Bare specifiers ("yjs") and subpath specifiers ("y-protocols/awareness",
      // "lib0/encoding") both have to resolve to the top-level package.
      const filter = new RegExp(`^${name}(/.*)?$`)
      build.onResolve({ filter }, (args) => {
        const subpath = args.path.slice(name.length) // "" or "/awareness"
        // Resolve as if imported from the top-level package, so subpath exports
        // go through that package's package.json.
        const target = subpath ? canonical(name) + subpath : canonical(name)
        return { path: Bun.resolveSync(target, here) }
      })
    }
  },
}

// One entry per page bundle. A demo's file name is its slug (app/lib/demos.rb),
// because demos/show.html.erb loads /<slug>.js.
const ENTRIES = [
  // Y.XmlFragment via lexxy-realtime's <lexxy-collaboration>. Lexxy's upload
  // code calls `await import("@rails/activestorage")`, an optional peer this app
  // doesn't install. The site has no uploads, and the editor mounts with
  // attachments="false", so that import never runs. Marking it external stops
  // the bundler from trying to resolve it.
  { entry: "src/lexxy.js", external: ["@rails/activestorage"] },
  "src/tiptap.js",       // Y.XmlFragment via Tiptap's Collaboration extension
  "src/spreadsheet.js",  // Y.Array of row Y.Maps, cells nested as Y.Maps
  "src/whiteboard.js",   // Y.Map of shape records
  "src/kanban.js",       // Y.Array of card Y.Maps
  { entry: "src/document.js", external: ["@rails/actioncable"] },
  "src/codemirror.js",   // Y.Text
  "src/hero.js",         // the home page replay; no Yjs, no cable
]

async function buildEntry(spec) {
  const { entry, external = [] } = typeof spec === "string" ? { entry: spec } : spec
  // An entry that imports CSS emits two outputs (JS + CSS); [name].[ext]
  // splits them, so src/lexxy.js -> lexxy.js plus lexxy.css.
  const result = await Bun.build({
    entrypoints: [resolve(here, entry)],
    outdir: resolve(here, "../public"),
    naming: "[name].[ext]",
    minify: true,
    external,
    plugins: [dedupeSingletons],
  })
  if (!result.success) {
    for (const log of result.logs) console.error(log)
    return false
  }
  console.log(`built ../public/${entry.replace("src/", "")}`)
  return true
}

async function build() {
  const results = await Promise.all(ENTRIES.map(buildEntry))
  return results.every(Boolean)
}

if (process.argv.includes("--watch")) {
  const { watch } = await import("node:fs")
  await build()
  let pending
  watch(resolve(here, "src"), { recursive: true }, () => {
    clearTimeout(pending)
    pending = setTimeout(build, 50) // debounce editor save bursts
  })
  console.log("watching src/ …")
} else if (!(await build())) {
  process.exit(1)
}
