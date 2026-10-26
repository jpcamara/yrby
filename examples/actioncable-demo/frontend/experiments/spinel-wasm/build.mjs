// Optional example build. Bundles host.js and copies the Spinel module, its
// Ruby source and ywasm into public/spinel-wasm/. build-wasm.sh compiles
// pixel_studio.wasm first; it needs Spinel and wasi-sdk, so it runs on its own.
/* global Bun */
import { mkdir, copyFile, access } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { buildYwasmBrowser } from "yrby-wasm-client/build"

const here = dirname(fileURLToPath(import.meta.url))
const out = resolve(here, "../../../public/spinel-wasm")
const module = resolve(here, "build/pixel_studio.wasm")
await access(module).catch(() => {
  console.error("build/pixel_studio.wasm is missing. Run ./build-wasm.sh first.")
  process.exit(1)
})
await mkdir(out, { recursive: true })
const yrs = await buildYwasmBrowser({
  ywasmDir: resolve(here, "node_modules/ywasm"),
  outputFile: resolve(here, "src/vendor/ywasm-browser.js"),
  wasmURL: "/spinel-wasm/ywasm_bg.wasm",
})
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
for (const [source, name] of [
  [module, "pixel_studio.wasm"],
  [resolve(here, "src/pixel_studio.rb"), "pixel_studio.rb"],
  [yrs.wasmPath, "ywasm_bg.wasm"],
  [yrs.licensePath, "YRS-LICENSE"],
]) await copyFile(source, resolve(out, name))
console.log("Built the Spinel Pixel Bay studio in public/spinel-wasm/")
