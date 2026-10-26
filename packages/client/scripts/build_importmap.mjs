// Builds the import-map assets the yrby-rails gem ships, from this package's
// source. bin/rails generate yrby:install pins them when the app has
// config/importmap.rb. Each module that has to be one instance per page gets
// its own asset and pin:
//
//   yjs.js          yjs, because Yjs checks constructors with instanceof.
//                   The app's editor binding imports this copy too.
//   yrby-client.js  yrby-client and yrby-client/element in one module, so
//                   the page has one session store and one element class.
//                   yjs and @rails/actioncable stay external; the app pins
//                   Rails' own actioncable.esm.js.
//
// y-protocols and lib0 keep no state that crosses assets, so they're bundled.
// CI rebuilds and fails if the committed assets are stale.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const here = dir => fileURLToPath(new URL(dir, import.meta.url));
const outdir = process.env.IMPORTMAP_ASSETS_OUT || here("../../../app/assets/javascript/yrby");

const asset = (name, contents, options = {}) => build({
  stdin: { contents, resolveDir: here("../src"), loader: "ts", sourcefile: `${name}.js` },
  outfile: `${outdir}/${name}.js`,
  bundle: true,
  format: "esm",
  sourcemap: true,
  logLevel: "warning",
  ...options,
});

await asset("yjs", `export * from "yjs";`);
await asset("yrby-client", `export * from "./index.ts";\nexport * from "./document_element.ts";`,
  { external: ["yjs", "@rails/actioncable"] });
