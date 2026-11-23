// Optional example build. Normal yrby-client consumers do not load either WASM runtime.
/* global Bun */
import { mkdir, copyFile, access } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { buildYwasmBrowser } from "yrby-wasm-client/build"

const here = dirname(fileURLToPath(import.meta.url))
const out = resolve(here, "../../../public/ruby-wasm")
const rubyClient = fileURLToPath(import.meta.resolve("yrby-wasm-client/ruby"))
await access(rubyClient)
await access(resolve(here, "src/pixel_peer.rb"))
await mkdir(out, { recursive: true })
const yrs = await buildYwasmBrowser({
  ywasmDir: resolve(here, "node_modules/ywasm"),
  outputFile: resolve(here, "src/vendor/ywasm-browser.js"),
  wasmURL: "/ruby-wasm/ywasm_bg.wasm",
})
const result = await Bun.build({
  entrypoints: [resolve(here, "src/bootstrap.js")],
  outdir: out,
  naming: "bootstrap.js",
  target: "browser",
  format: "esm",
  minify: false,
})
if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}
for (const [source, name] of [
  [yrs.wasmPath, "ywasm_bg.wasm"],
  [yrs.licensePath, "YRS-LICENSE"],
  [rubyClient, "yrby_wasm.rb"],
  [resolve(here, "node_modules/@ruby/3.4-wasm-wasi/dist/ruby+stdlib.wasm"), "ruby.wasm"],
  [resolve(here, "node_modules/@ruby/3.4-wasm-wasi/dist/LICENSE"), "RUBY-LICENSE"],
  [resolve(here, "node_modules/@ruby/3.4-wasm-wasi/dist/NOTICE"), "RUBY-NOTICE"],
  [resolve(here, "src/pixel_peer.rb"), "pixel_peer.rb"],
]) await copyFile(source, resolve(out, name))
console.log("Built optional yrby WASM client and Ruby Pixel Bay in public/ruby-wasm/")
