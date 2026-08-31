// Bundles the demo pages into ../public, one file per demo.
//
// Every entry shares one copy of yjs (and the other CRDT singletons). yrby-client
// declares yjs/y-protocols as optional *peer* dependencies and depends on lib0
// directly, so a package manager is free to install a second copy of any of them
// nested under yrby-client. If that happens, the provider's `import "yjs"`
// resolves to the nested copy while the editor (y-prosemirror, y-codemirror.next)
// uses the top-level one — two Y.js instances in one bundle. That trips Yjs's
// "already imported" guard and breaks constructor checks, so y-prosemirror throws
// "Method unimplemented" applying remote updates: the editor never renders
// incoming content and the next local keystroke clobbers it. Nothing about the
// failure points at module resolution, which is why the pinning below is
// unconditional rather than something to add when it breaks.
//
//   bun build.mjs            # one-shot build
//   bun build.mjs --watch    # rebuild on change
/* global Bun */
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))

// One canonical resolution per shared singleton, taken from the top-level
// node_modules so every importer shares it.
const SINGLETONS = ["yjs", "y-protocols", "lib0"]
const canonical = (name) => resolve(here, "node_modules", name)

const dedupeSingletons = {
  name: "dedupe-singletons",
  setup(build) {
    for (const name of SINGLETONS) {
      // Bare specifier ("yjs") and subpath specifiers ("y-protocols/awareness",
      // "lib0/encoding") both have to land in the one canonical package.
      const filter = new RegExp(`^${name}(/.*)?$`)
      build.onResolve({ filter }, (args) => {
        const subpath = args.path.slice(name.length) // "" or "/awareness"
        // Resolve as if imported from the top-level package, so subpath exports
        // map through the canonical package.json.
        const target = subpath ? canonical(name) + subpath : canonical(name)
        return { path: Bun.resolveSync(target, here) }
      })
    }
  },
}

// One entry per demo page. The file name is the demo slug (app/lib/demos.rb),
// because demos/show.html.erb loads /<slug>.js.
const ENTRIES = [
  "src/tiptap.js",       // Y.XmlFragment via Tiptap's Collaboration extension
  "src/spreadsheet.js",  // Y.Array of row Y.Maps, cells nested as Y.Maps
  "src/whiteboard.js",   // Y.Map of shape records
  "src/kanban.js",       // Y.Array of card Y.Maps
  "src/codemirror.js",   // Y.Text
]

async function buildEntry(entry) {
  const result = await Bun.build({
    entrypoints: [resolve(here, entry)],
    outdir: resolve(here, "../public"),
    naming: "[name].[ext]",
    minify: true,
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
