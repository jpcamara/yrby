// Optional example build. Bundles host.js and copies the Spinel module and its
// Ruby source into public/spinel-wasm/. build-wasm.sh compiles
// pixel_studio.wasm first; it needs Spinel, wasi-sdk and y-crdt, so it runs on
// its own.
/* global Bun */
import { mkdir, copyFile, access } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const out = resolve(here, "../../../public/spinel-wasm")
const build = resolve(here, "build")
await access(resolve(build, "pixel_studio.wasm")).catch(() => {
  console.error("build/pixel_studio.wasm is missing. Run ./build-wasm.sh first.")
  process.exit(1)
})
await mkdir(out, { recursive: true })
const result = await Bun.build({
  entrypoints: [resolve(here, "src/host.js")],
  outdir: out,
  naming: "host.js",
  target: "browser",
  format: "esm",
  minify: false,
})
if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}
for (const name of ["pixel_studio.wasm", "YRS-LICENSE"]) await copyFile(resolve(build, name), resolve(out, name))
for (const name of ["pixel_studio.rb", "yrs.rb", "sync.rb"]) await copyFile(resolve(here, "src", name), resolve(out, name))
console.log("Built the Spinel Pixel Bay studio in public/spinel-wasm/")
