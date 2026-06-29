// Bundles the demo's frontend with a single shared copy of yjs (and the other
// CRDT singletons). @yrby/client lists yjs/y-protocols as *devDependencies*
// so it can build its own dist/, which leaves a nested
// packages/client/node_modules/yjs on disk. Without deduping, Bun
// resolves the provider's `import "yjs"` to that nested copy while the editor
// (Tiptap/y-prosemirror) uses the top-level one — two Y.js instances in one
// bundle. That trips Yjs's "already imported" guard and breaks constructor
// checks, so y-prosemirror throws "Method unimplemented" applying remote
// updates: the editor view never renders incoming content and the next local
// keystroke clobbers it. Pinning these modules to one canonical path keeps the
// editor and provider on the same Y.Doc internals.
//
//   bun build.mjs            # one-shot build
//   bun build.mjs --watch    # rebuild on change
/* global Bun */
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))

// One canonical resolution per shared singleton, taken from the top-level
// node_modules so every importer shares it. yjs / y-protocols / lib0 are the
// CRDT singletons; `lexical` + `@lexical/yjs` are added for the Lexxy page.
// Two copies of `lexical` would break Lexical's node-class identity the same way
// two copies of yjs break y-prosemirror. `@lexical/yjs` must be pinned too
// because lexxy-realtime (a file:/sibling dep) imports it from OUTSIDE the demo's
// node_modules tree -- without this, bundling lexxy.js can't resolve it from the
// lexxy-realtime package location (e.g. inside Docker, where the dep is a real
// sibling dir rather than a copy under node_modules).
const SINGLETONS = ["yjs", "y-protocols", "lib0", "lexical", "@lexical/yjs"]
const canonical = (name) => resolve(here, "node_modules", name)

const dedupeSingletons = {
  name: "dedupe-crdt-singletons",
  setup(build) {
    for (const name of SINGLETONS) {
      // Bare specifier ("yjs") and subpath specifiers ("y-protocols/awareness",
      // "lib0/encoding") both have to land in the one canonical package.
      const filter = new RegExp(`^${name}(/.*)?$`)
      build.onResolve({ filter }, (args) => {
        const subpath = args.path.slice(name.length) // "" or "/awareness"
        // Resolve the specifier as if it were imported from the top-level
        // package, so subpath exports map through the canonical package.json.
        const target = subpath ? canonical(name) + subpath : canonical(name)
        return { path: Bun.resolveSync(target, here) }
      })
    }
  },
}

// The Tiptap page (app.js) and the Lexxy page (lexxy.js) are independent
// entrypoints sharing the dedupe plugin. The Lexxy bundle also imports Lexxy's
// CSS, which Bun emits as ../public/lexxy.css.
const ENTRIES = [
  { entry: "src/app.js", name: "app.js" },
  { entry: "src/lexxy.js", name: "lexxy.js" },
  // "Opaque state" demos: the SAME DocumentChannel syncs any Yjs shape.
  { entry: "src/codemirror.js", name: "codemirror.js" }, // Y.Text + CodeMirror 6
  { entry: "src/whiteboard.js", name: "whiteboard.js" }, // Y.Map of shapes
  { entry: "src/kanban.js", name: "kanban.js" },         // Y.Array of card Y.Maps
  { entry: "src/forms.js", name: "forms.js" },           // Y.Map of fields
]

// Lexxy dynamically imports @rails/activestorage for attachment uploads, which
// this collaboration demo doesn't use. Stub it so the bundle is self-contained
// (the Tiptap entry never imports it, so this is a no-op there).
const stubActivestorage = {
  name: "stub-activestorage",
  setup(build) {
    build.onResolve({ filter: /^@rails\/activestorage$/ }, () => ({
      path: resolve(here, "src/stubs/activestorage.js"),
    }))
  },
}

async function buildEntry({ entry, name }) {
  // An entry that imports CSS emits two entry-category outputs (JS + CSS), so the
  // naming needs an [ext] placeholder to split them -- otherwise both want the
  // same path. [name] is the source basename, so src/lexxy.js -> lexxy.js and its
  // CSS -> lexxy.css; src/app.js -> app.js.
  const result = await Bun.build({
    entrypoints: [resolve(here, entry)],
    outdir: resolve(here, "../public"),
    naming: "[name].[ext]",
    minify: true,
    plugins: [dedupeSingletons, stubActivestorage],
  })
  if (!result.success) {
    for (const log of result.logs) console.error(log)
    return false
  }
  console.log(`built ../public/${name}`)
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
