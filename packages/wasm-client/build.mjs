import { mkdir, readFile, writeFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"

export const YWASM_VERSION = "0.28.0"

/**
 * Convert the pinned wasm-bindgen Node loader to browser ESM without altering
 * its generated bindings. Bundlers can import outputFile; callers copy the
 * returned WASM and license paths into their own public assets directory.
 */
export async function buildYwasmBrowser({ ywasmDir, outputFile, wasmURL = "./ywasm_bg.wasm" } = {}) {
  if (!ywasmDir || !outputFile) throw new TypeError("ywasmDir and outputFile are required")
  const directory = resolve(ywasmDir)
  const [manifest, original] = await Promise.all([
    readFile(resolve(directory, "package.json"), "utf8").then(JSON.parse),
    readFile(resolve(directory, "ywasm.js"), "utf8"),
  ])
  if (manifest.version !== YWASM_VERSION) {
    throw new Error(`Browser loader transform requires ywasm ${YWASM_VERSION}; found ${manifest.version}. Review the transform before upgrading.`)
  }
  const boundary = original.indexOf("const wasmPath =")
  if (boundary < 0 || !original.slice(boundary).includes("wasm.__wbindgen_start();")) {
    throw new Error("Unexpected ywasm loader; review the pinned browser transform")
  }
  let exports = 0
  let bindings = original.slice(0, boundary).replace(/^exports\.(\w+) = (\w+);$/gm, (_line, name, value) => {
    if (name !== value) throw new Error("Unexpected aliased ywasm export")
    exports++
    return `export { ${name} };`
  })
  if (!exports || /\brequire\s*\(|\bexports\.|\b__dirname\b/.test(bindings)) {
    throw new Error("Unconverted Node code in ywasm bindings")
  }
  bindings = `// Generated from ywasm ${YWASM_VERSION} by yrby-wasm-client/build.\n${bindings}
let wasm;
let initialization;
export default function init(url = new URL(${JSON.stringify(wasmURL)}, import.meta.url)) {
  return initialization ||= (async () => {
    const response = await fetch(url);
    if (!response.ok) throw new Error("Could not load Yrs WASM: HTTP " + response.status);
    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), __wbg_get_imports());
    wasm = instance.exports;
    wasm.__wbindgen_start();
    return wasm;
  })().catch(error => {
    initialization = undefined;
    throw error;
  });
}
`
  await mkdir(dirname(resolve(outputFile)), { recursive: true })
  await writeFile(outputFile, bindings)
  return {
    version: YWASM_VERSION,
    bindingsPath: resolve(outputFile),
    wasmPath: resolve(directory, "ywasm_bg.wasm"),
    licensePath: resolve(directory, "LICENSE"),
  }
}
