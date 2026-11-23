import { DefaultRubyVM } from "@ruby/wasm-wasi/dist/browser"
import { createConsumer } from "@rails/actioncable"
import { createRubyHost } from "yrby-wasm-client/ruby-host"
import initYrs, * as Y from "./vendor/ywasm-browser.js"

const root = document.getElementById("pixel-studio")
const runtime = document.getElementById("wasm-runtime")
async function fetchAsset(path, format) {
  const response = await fetch(path)
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`)
  return response[format]()
}
try {
  if (!root || !runtime) throw new Error("The Ruby studio is missing its shared interface")
  runtime.textContent = "Loading the Ruby runtime…"
  const [rubyBytes, clientSource, pixelSource] = await Promise.all([
    fetchAsset("/ruby-wasm/ruby.wasm", "arrayBuffer"),
    fetchAsset("/ruby-wasm/yrby_wasm.rb", "text"),
    fetchAsset("/ruby-wasm/pixel_peer.rb", "text"),
    initYrs("/ruby-wasm/ywasm_bg.wasm"),
  ])
  window.YrbyWasm = createRubyHost({ Y, createConsumer })
  runtime.textContent = "Starting Ruby in this tab…"
  const module = await WebAssembly.compile(rubyBytes)
  const { vm } = await DefaultRubyVM(module)
  // Ruby assigns its reusable client for the experiment's browser diagnostics.
  window.__rubyPixel = { vm, ready: false }
  await vm.evalAsync(clientSource)
  await vm.evalAsync(pixelSource)
  window.__rubyPixel.ready = true
} catch (error) {
  window.__rubyPixel?.client?.destroy?.()
  const message = document.getElementById("wasm-error")
  if (message) {
    message.hidden = false
    message.textContent = `The Ruby experiment could not start: ${error.message}. The main Pixel Bay studio is still available.`
  }
  if (runtime) runtime.textContent = "Could not start Ruby"
  const connection = document.getElementById("connection-status")
  if (connection) connection.textContent = "Experiment unavailable"
  const dot = document.getElementById("connection-dot")
  if (dot) dot.className = "live-dot offline"
  const pending = document.getElementById("wasm-pending")
  if (pending) pending.textContent = "Browser client unavailable."
  console.error(error)
}
