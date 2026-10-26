// Hosts the Spinel-compiled Pixel Bay studio. pixel_studio.rb runs as native
// WebAssembly with no Ruby interpreter; this file is the browser surface it
// imports: DOM events, the canvas, fetch, and the yrby-wasm-client document.
import { createConsumer } from "@rails/actioncable"
import { createClient } from "yrby-wasm-client"
import initYrs, * as Y from "./vendor/ywasm-browser.js"

const root = document.getElementById("pixel-studio")
const runtime = document.getElementById("wasm-runtime")
const canvas = document.getElementById("mural-canvas")
const context = canvas?.getContext("2d", { alpha: false })
const encoder = new TextEncoder()
const decoder = new TextDecoder()

let wasm
let client
let undo
let current = null
let depth = 0
const queue = []
const listeners = { client: {}, undo: {} }

// Strings into Ruby share one buffer: Ruby copies a returned :str at once.
let scratch = 0
let scratchSize = 0
const memory = () => new Uint8Array(wasm.memory.buffer)
function read(pointer) {
  const bytes = memory()
  let end = pointer
  while (bytes[end]) end++
  return decoder.decode(bytes.subarray(pointer, end))
}
function give(value) {
  const bytes = encoder.encode(value == null ? "" : String(value))
  if (bytes.length + 1 > scratchSize) {
    if (scratch) wasm.free(scratch)
    scratchSize = Math.max(4096, bytes.length * 2 + 1)
    scratch = wasm.malloc(scratchSize)
  }
  const view = memory()
  view.set(bytes, scratch)
  view[scratch + bytes.length] = 0
  return scratch
}

// One Ruby call at a time. An event that arrives while Ruby is running (a
// client callback fired by a Ruby write, say) waits for the call to finish.
function dispatch(code, event = null) {
  if (depth > 0) {
    queue.push([code, event])
    return
  }
  depth++
  try {
    current = event
    wasm.dispatch(code)
    while (queue.length) {
      const [next, nextEvent] = queue.shift()
      current = nextEvent
      wasm.dispatch(next)
    }
  } finally {
    current = null
    depth--
  }
}

function element(id) {
  if (id === "window") return window
  if (id === "document") return document
  return document.getElementById(id)
}
const bool = value => value !== 0

// Ruby gets client IDs as strings: they are uint32, past a 32-bit Integer.
function statusJSON() {
  const status = JSON.parse(client.getStatus())
  status.clientID = String(status.clientID)
  for (const peer of status.peers) peer.clientID = String(peer.clientID)
  return JSON.stringify(status)
}

function eventFields(event) {
  const target = event.target
  return {
    event,
    inEditor: !!target?.closest?.("input,textarea,[contenteditable=true]"),
    onCanvas: target === canvas,
  }
}

const invites = new Map()
async function invite(url, stopVersion, token) {
  const controller = new AbortController()
  invites.set(token, controller)
  const token_ = document.querySelector('meta[name="csrf-token"]')
  try {
    const response = await fetch(url, {
      method: "POST", credentials: "same-origin", signal: controller.signal,
      headers: { Accept: "text/event-stream", "X-CSRF-Token": token_?.content ?? "", "X-Pixel-Stop-Version": stopVersion },
    })
    dispatch(INVITE_RESPONSE, { values: { token, status: response.status, ok: response.ok, body: !!response.body } })
    if (!response.ok) {
      await response.body?.cancel()
      return
    }
    if (!response.body) return
    // Keep Falcon's streaming artist request open until it ends.
    const reader = response.body.getReader()
    try {
      while (!(await reader.read()).done) { /* drain */ }
    } finally {
      reader.releaseLock()
    }
    dispatch(INVITE_DONE, { values: { token } })
  } catch (error) {
    dispatch(INVITE_ERROR, { values: { token, name: error?.name ?? "Error", message: error?.message ?? String(error) } })
  } finally {
    invites.delete(token)
  }
}

const INVITE_RESPONSE = 27
const INVITE_DONE = 28
const INVITE_ERROR = 29
const SHARED = 30

function field(name) {
  if (!current) return undefined
  if (current.values && name in current.values) return current.values[name]
  if (name in current) return current[name]
  return current.event?.[name]
}

const host = {
  host_log: pointer => console.log("[spinel]", read(pointer)),
  host_error(cls, message) {
    const text = `${read(cls)}: ${read(message)}`
    console.error("[spinel]", text)
    window.__spinelPixel.errors.push(text)
  },

  host_listen(target, type, code) {
    const id = read(target)
    const name = read(type)
    if (id === "client" || id === "undo") {
      listeners[id][name] = code
      return
    }
    if (name === "resize" && id !== "window") {
      new ResizeObserver(() => dispatch(code)).observe(element(id))
      return
    }
    element(id).addEventListener(name, event => dispatch(code, eventFields(event)))
  },
  host_timeout: (delay, code) => setTimeout(() => dispatch(code), delay),
  host_clear_timeout: id => clearTimeout(id),
  host_frame: code => { requestAnimationFrame(() => dispatch(code)) },
  host_ev_num: name => Number(field(read(name)) ?? 0),
  host_ev_str: name => give(field(read(name)) ?? ""),
  host_ev_bool: name => (field(read(name)) ? 1 : 0),
  host_ev_prevent: () => current?.event?.preventDefault(),

  host_create(parent, tag, id) {
    const node = document.createElement(read(tag))
    node.id = read(id)
    element(read(parent)).appendChild(node)
  },
  host_clear: id => element(read(id)).replaceChildren(),
  host_text: (id, text) => { element(read(id)).textContent = read(text) },
  host_prop: (id, name, value) => { element(read(id))[read(name)] = read(value) },
  host_flag: (id, name, value) => { element(read(id))[read(name)] = bool(value) },
  host_attr: (id, name, value) => element(read(id)).setAttribute(read(name), read(value)),
  host_class: (id, name, on) => element(read(id)).classList.toggle(read(name), bool(on)),
  host_style(id, name, value) {
    const style = element(read(id)).style
    const property = read(name)
    if (property.startsWith("--")) style.setProperty(property, read(value))
    else style[property] = read(value)
  },
  host_get(id, path) {
    let value = element(read(id))
    for (const key of read(path).split(".")) value = value?.[key]
    return give(value ?? "")
  },
  host_rect: (id, side) => element(read(id)).getBoundingClientRect()[read(side)],
  host_active: () => give(document.activeElement?.id ?? ""),
  host_focus: id => element(read(id)).focus({ preventScroll: true }),
  host_capture(id, pointer, on) {
    const node = element(read(id))
    if (bool(on)) node.setPointerCapture(pointer)
    else if (node.hasPointerCapture(pointer)) node.releasePointerCapture(pointer)
  },

  host_fill(color, left, top, width, height) {
    context.imageSmoothingEnabled = false
    context.fillStyle = read(color)
    context.fillRect(left, top, width, height)
  },
  host_dpr: () => window.devicePixelRatio || 1,
  host_storage_get(key) {
    try { return give(localStorage.getItem(read(key)) ?? "") } catch { return give("") }
  },
  host_storage_set(key, value) {
    try { localStorage.setItem(read(key), read(value)) } catch { /* presence still works */ }
  },
  host_share() {
    const url = location.href
    navigator.clipboard.writeText(url).then(
      () => dispatch(SHARED),
      () => prompt("Copy this link to invite a friend:", url),
    )
  },
  host_invite: (url, stopVersion, token) => { invite(read(url), read(stopVersion), token) },
  host_abort: token => invites.get(token)?.abort(),

  host_connect(options) {
    client = createClient({ ...JSON.parse(read(options)), Y, consumer: createConsumer(), manageConsumer: true })
    client.onChange(() => listeners.client.change && dispatch(listeners.client.change))
    client.onStatus(() => listeners.client.status && dispatch(listeners.client.status))
    window.__spinelPixel.client = client
    client.connect()
  },
  host_online: on => (bool(on) ? client.connect() : client.disconnect()),
  host_status: () => give(statusJSON()),
  host_presence: json => client.setPresenceJSON(read(json)),
  host_map_json: name => give(client.map(read(name)).readJSON()),
  host_map_get: (name, key) => give(client.map(read(name)).getJSON(read(key))),
  host_map_set: (name, key, json) => client.map(read(name)).setJSON(read(key), read(json)),
  host_begin: origin => client.beginTransaction(read(origin)),
  host_commit: () => client.endTransaction(),
  host_undo_create(scope, origin, timeout) {
    undo = client.createUndoManager([read(scope)], read(origin), timeout)
    undo.onChange(() => listeners.undo.change && dispatch(listeners.undo.change))
  },
  // 0 stops capturing, so the next paint starts its own undo step.
  host_undo: action => (action === 0 ? undo.stopCapturing() : action === 1 ? undo.undo() : undo.redo()),
  host_can_undo: () => (undo.canUndo ? 1 : 0),
}

function wasi() {
  const ENOSYS = 52
  const EBADF = 8
  let exit = null
  const view = () => new DataView(wasm.memory.buffer)
  const lines = { 1: "", 2: "" }
  return {
    exitCode: () => exit,
    imports: {
      environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0 },
      environ_get: () => 0,
      clock_time_get(_id, _precision, out) {
        view().setBigUint64(out, BigInt(Math.round(performance.timeOrigin * 1e6 + performance.now() * 1e6)), true)
        return 0
      },
      fd_write(fd, iovs, count, written) {
        const data = view()
        let total = 0
        for (let i = 0; i < count; i++) {
          const pointer = data.getUint32(iovs + i * 8, true)
          const length = data.getUint32(iovs + i * 8 + 4, true)
          if (fd === 1 || fd === 2) {
            lines[fd] += decoder.decode(memory().subarray(pointer, pointer + length))
            const parts = lines[fd].split("\n")
            lines[fd] = parts.pop()
            for (const line of parts) (fd === 2 ? console.warn : console.log)("[spinel]", line)
          }
          total += length
        }
        data.setUint32(written, total, true)
        return 0
      },
      fd_prestat_get: () => EBADF,
      // stdin, stdout and stderr are character devices; nothing else is open.
      fd_fdstat_get(fd, out) {
        if (fd > 2) return EBADF
        const data = view()
        for (let i = 0; i < 24; i += 4) data.setUint32(out + i, 0, true)
        data.setUint8(out, 2)
        data.setBigUint64(out + 8, 0xffffffffffffffffn, true)
        data.setBigUint64(out + 16, 0xffffffffffffffffn, true)
        return 0
      },
      proc_exit(code) {
        exit = code
        throw new Error(`Spinel module exited with status ${code}`)
      },
    },
    proxy() {
      return new Proxy(this.imports, { get: (target, name) => target[name] ?? (() => ENOSYS) })
    },
  }
}

try {
  if (!root || !runtime || !context) throw new Error("The studio is missing its shared interface")
  window.__spinelPixel = { ready: false, errors: [] }
  runtime.textContent = "Loading the Spinel module…"
  const [bytes] = await Promise.all([
    fetch("/spinel-wasm/pixel_studio.wasm").then(response => {
      if (!response.ok) throw new Error(`pixel_studio.wasm: HTTP ${response.status}`)
      return response.arrayBuffer()
    }),
    initYrs("/spinel-wasm/ywasm_bg.wasm"),
  ])
  const system = wasi()
  const started = performance.now()
  const { instance } = await WebAssembly.instantiate(bytes, { env: host, wasi_snapshot_preview1: system.proxy() })
  wasm = instance.exports
  wasm._initialize()
  if (wasm.init() !== 0) throw new Error(window.__spinelPixel.errors.at(-1) ?? "Ruby raised while loading")
  depth++
  try {
    if (wasm.start() !== 0) throw new Error(window.__spinelPixel.errors.at(-1) ?? "Ruby raised while starting")
  } finally {
    depth--
  }
  while (queue.length) dispatch(...queue.shift())
  window.__spinelPixel.module = { bytes: bytes.byteLength, startMs: performance.now() - started }
  window.__spinelPixel.dispatch = dispatch
  window.__spinelPixel.ready = true
} catch (error) {
  window.__spinelPixel?.client?.destroy?.()
  const message = document.getElementById("wasm-error")
  if (message) {
    message.hidden = false
    message.textContent = `The Spinel experiment could not start: ${error.message}. The main Pixel Bay studio is still available.`
  }
  if (runtime) runtime.textContent = "Could not start the Spinel module"
  const connection = document.getElementById("connection-status")
  if (connection) connection.textContent = "Experiment unavailable"
  const dot = document.getElementById("connection-dot")
  if (dot) dot.className = "live-dot offline"
  const pending = document.getElementById("wasm-pending")
  if (pending) pending.textContent = "Browser client unavailable."
  console.error(error)
}
