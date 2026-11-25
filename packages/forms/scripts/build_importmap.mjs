// Builds the import-map assets the yrby-forms gem ships, from this package's
// source:
//
//   yrby-forms.js  yrby-forms. yjs and yrby-client/element stay external:
//                  they are the pins bin/rails generate yrby:install adds, and
//                  the page has to hold one copy of each.
//   column.js      yrby-forms/column, which needs yjs only.
//
// CI rebuilds and fails if the committed assets are stale.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const here = dir => fileURLToPath(new URL(dir, import.meta.url));
const outdir = process.env.IMPORTMAP_ASSETS_OUT || here("../../../app/assets/javascript/yrby-forms");

const asset = (name, entry, external) => build({
  entryPoints: [here(`../src/${entry}.ts`)],
  outfile: `${outdir}/${name}.js`,
  bundle: true,
  format: "esm",
  sourcemap: true,
  logLevel: "warning",
  external,
});

await asset("yrby-forms", "index", ["yjs", "yrby-client/element"]);
await asset("column", "column", ["yjs"]);
