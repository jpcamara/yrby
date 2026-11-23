// Hosts the Spinel-compiled Pixel Bay studio. pixel_studio.rb runs as native
// WebAssembly with no Ruby interpreter, and yrs is linked into the same module.
// This file is the browser surface it imports: DOM events, the canvas, fetch,
// and the ActionCable socket the sync protocol runs over.
import { createConsumer } from "@rails/actioncable"

const root = document.getElementById("pixel-studio")
const runtime = document.getElementById("wasm-runtime")
const canvas = document.getElementById("mural-canvas")
const context = canvas?.getContext("2d", { alpha: false })
const encoder = new TextEncoder()
const decoder = new TextDecoder()

let wasm
let current = null
let depth = 0
const queue = []
let consumer = null
let subscription = null
let reply = ""

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

// One Ruby call at a time. An event that arrives while Ruby is running waits
// for the call to finish.
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

const CABLE_CONNECTED = 20
const CABLE_DISCONNECTED = 21
const CABLE_REJECTED = 22
const INVITE_RESPONSE = 27
const INVITE_DONE = 28
const INVITE_ERROR = 29
const SHARED = 30
const CABLE_MESSAGE = 31
const INSPECT_STATUS = 35
const INSPECT_MAP = 36

// Cable callbacks can fire inside create(); deliver them afterwards, and only
// for the current subscription.
function cable(channel, id) {
  consumer ??= createConsumer()
  const later = (code, event) => queueMicrotask(() => { if (subscription === created) dispatch(code, event) })
  const created = consumer.subscriptions.create({ channel, id }, {
    received: message => later(CABLE_MESSAGE, { values: { json: JSON.stringify(message) } }),
    connected: () => later(CABLE_CONNECTED),
    disconnected: () => later(CABLE_DISCONNECTED),
    rejected: () => later(CABLE_REJECTED),
  })
  subscription = created
  consumer.connect()
}

// Reads Ruby's state for tests and the console, outside any other call.
function inspect(code, values) {
  if (depth > 0) throw new Error("The studio is busy")
  reply = ""
  dispatch(code, values && { values })
  return reply
}

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

  host_now: () => Date.now(),
  // A client ID. 31 bits stays a machine Integer in 32-bit wasm Ruby.
  host_random: () => (crypto.getRandomValues(new Uint32Array(1))[0] >>> 1) || 1,

  host_cable_open: (channel, id) => cable(read(channel), read(id)),
  host_cable_send(update, sequence) {
    const message = { update: read(update) }
    if (sequence >= 0) message.id = sequence
    subscription?.send(message)
  },
  // Let a final presence frame go out before the subscription closes.
  host_cable_close() {
    const previous = subscription
    subscription = null
    queueMicrotask(() => {
      previous?.unsubscribe()
      if (!subscription) consumer?.disconnect()
    })
  },

  host_reply: text => { reply = read(text) },
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
      random_get(pointer, length) {
        for (let at = 0; at < length; at += 65536) {
          crypto.getRandomValues(memory().subarray(pointer + at, pointer + Math.min(length, at + 65536)))
        }
        return 0
      },
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
  const response = await fetch("/spinel-wasm/pixel_studio.wasm")
  if (!response.ok) throw new Error(`pixel_studio.wasm: HTTP ${response.status}`)
  const bytes = await response.arrayBuffer()
  const system = wasi()
  const started = performance.now()
  const { instance } = await WebAssembly.instantiate(bytes, { env: host, wasi_snapshot_preview1: system.proxy() })
  wasm = instance.exports
  window.__spinelPixel.client = {
    getStatus: () => inspect(INSPECT_STATUS),
    map: name => ({ readJSON: () => inspect(INSPECT_MAP, { name }) }),
  }
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
  subscription?.unsubscribe()
  consumer?.disconnect()
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
