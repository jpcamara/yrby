// Experimental Yrs/WASM client. The host initializes Yrs and supplies a cable
// consumer; this module owns a document and subscription, never a Ruby runtime.
import { ReliableSync } from "yrby-client/reliable"
import { toBase64, fromBase64 } from "yrby-client/base64"
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"

export const LOCAL_ORIGIN = "yrby-wasm-local"
const REMOTE_ORIGIN = "yrby-wasm-remote"

function frame(type, payload, subtype) {
  const writer = encoding.createEncoder()
  encoding.writeVarUint(writer, type)
  if (subtype !== undefined) encoding.writeVarUint(writer, subtype)
  encoding.writeVarUint8Array(writer, payload)
  return encoding.toUint8Array(writer)
}

function decodeFrame(bytes) {
  const reader = decoding.createDecoder(bytes)
  const type = decoding.readVarUint(reader)
  if (type !== 0 && type !== 1) return null
  const subtype = type === 0 ? decoding.readVarUint(reader) : undefined
  if (type === 0 && subtype > 2) return null
  const payload = decoding.readVarUint8Array(reader)
  if (decoding.hasContent(reader)) throw new Error("Protocol frame has trailing bytes")
  if (type === 1) {
    // Validate the whole awareness envelope before allowing a partial apply.
    const inner = decoding.createDecoder(payload)
    const count = decoding.readVarUint(inner)
    for (let i = 0; i < count; i++) {
      decoding.readVarUint(inner)
      decoding.readVarUint(inner)
      const state = JSON.parse(decoding.readVarString(inner))
      if (state !== null && (typeof state !== "object" || Array.isArray(state))) {
        throw new TypeError("Awareness states must be objects or null")
      }
    }
    if (decoding.hasContent(inner)) throw new Error("Awareness frame has trailing bytes")
  }
  return { type, subtype, payload }
}

function index(value, maximum, name = "index") {
  if (!Number.isInteger(value) || value < 0 || value > maximum) {
    throw new RangeError(`${name} must be an integer between 0 and ${maximum}`)
  }
  return value
}

function parsePresence(json) {
  const state = JSON.parse(json)
  if (state !== null && (typeof state !== "object" || Array.isArray(state))) {
    throw new TypeError("Presence must be a JSON object or null")
  }
  return state
}

/**
 * Create an experimental client over an initialized ywasm module. Does not
 * connect automatically. `manageConsumer` is appropriate only for a consumer
 * created exclusively for this client; shared application consumers stay open.
 */
export function createClient({
  Y, consumer, channel = "DocumentChannel", params = {}, localState = null,
  resendInterval, onError = (error, context) => console.warn(`[yrby-wasm] ${context}:`, error),
  manageConsumer = false,
} = {}) {
  if (!Y?.YDoc || !Y?.Awareness) throw new TypeError("An initialized ywasm module is required")
  if (typeof consumer?.subscriptions?.create !== "function") throw new TypeError("A cable consumer is required")
  if (typeof channel !== "string" || !channel) throw new TypeError("A channel name is required")
  if (resendInterval !== undefined && (!Number.isFinite(resendInterval) || resendInterval <= 0)) {
    throw new TypeError("resendInterval must be positive")
  }
  let savedPresence = parsePresence(JSON.stringify(localState))
  const clientID = crypto.getRandomValues(new Uint32Array(1))[0]
  // Awareness takes ownership of the initial wrapper. Its accessor returns a
  // new wrapper around the same doc; using the moved original would trap WASM.
  const awareness = new Y.Awareness(new Y.YDoc({ clientID }))
  const doc = awareness.doc
  const roots = new Map()
  const undoManagers = new Set()
  const changes = new Set()
  const statuses = new Set()
  const providerStatuses = new Set()
  const ackWaiters = new Set()
  const pendingLocal = []
  const channelParams = { ...params }
  let subscription = null
  let generation = 0
  let connected = false
  let synced = false
  let destroyed = false
  let applyingRemote = false
  let activeTransaction = null
  let error = ""
  let openingRequest = null
  let notificationsQueued = false
  let changed = false
  let lastStatus = ""
  let lastProviderStatus = "disconnected"
  let restoreAfterPageShow = false
  let everSynced = false
  let resolveSynced
  const whenSynced = new Promise(resolve => { resolveSynced = resolve })
  const stats = { localUpdates: 0, remoteUpdates: 0, acknowledgments: 0 }

  const checkAlive = () => { if (destroyed) throw new Error("WASM client is destroyed") }
  const checkNoTransaction = () => {
    checkAlive()
    if (activeTransaction) throw new Error("Finish the active transaction first")
  }
  const providerStatus = () => !subscription ? "disconnected" : !connected ? "connecting" : synced ? "synced" : "connected"
  const pendingCount = () => delivery.pending.length + pendingLocal.length
  const status = () => JSON.stringify({
    status: providerStatus(), connected, synced, offline: !subscription,
    pending: pendingCount(), clientID, error,
    peers: [...awareness.getStates()].map(([id, state]) => ({ ...state, clientID: Number(id) })),
    canUndo: [...undoManagers].some(manager => manager.canUndo),
    canRedo: [...undoManagers].some(manager => manager.canRedo),
  })

  function failed(reason, context = "client") {
    error = reason instanceof Error ? reason.message : String(reason)
    try { onError(reason, context) } catch (callbackError) { console.warn(callbackError) }
    notify()
  }

  function dispatch(listeners, ...args) {
    for (const listener of [...listeners]) {
      try { listener(...args) } catch (reason) { failed(reason, "callback") }
    }
  }

  function notify(documentChanged = false) {
    changed ||= documentChanged
    if (notificationsQueued || destroyed) return
    notificationsQueued = true
    // Neither runtime permits arbitrary synchronous re-entry from a Yrs
    // observer. Cross into Ruby only after the transaction has been released.
    queueMicrotask(() => {
      notificationsQueued = false
      if (destroyed) return
      flushLocal()
      const documentChanged = changed
      changed = false
      if (documentChanged) {
        dispatch(changes)
        for (const manager of undoManagers) manager.notify()
      }
      const next = status()
      if (next !== lastStatus) { lastStatus = next; dispatch(statuses, next) }
      const nextProvider = providerStatus()
      if (nextProvider !== lastProviderStatus) {
        lastProviderStatus = nextProvider
        dispatch(providerStatuses, { status: nextProvider })
      }
    })
  }

  function observeSend(result) {
    if (result && typeof result.then === "function") Promise.resolve(result).catch(reason => failed(reason, "send"))
  }

  function send(bytes, id) {
    if (!connected || !subscription || destroyed) return
    try {
      const update = toBase64(bytes)
      if (bytes[0] === 1 && typeof subscription.whisper === "function") {
        observeSend(subscription.whisper({ awareness: update }))
      } else {
        observeSend(subscription.send(id === undefined ? { update } : { update, id }))
      }
    } catch (reason) { failed(reason, "send") }
  }

  const delivery = new ReliableSync({
    merge: updates => Y.mergeUpdatesV1(updates), resendInterval,
    send: (update, id) => send(frame(0, update, 2), id),
  })

  function flushLocal() {
    if (destroyed || activeTransaction) return
    while (pendingLocal.length) delivery.enqueue(pendingLocal.shift())
  }

  function settleAcknowledgments() {
    if (pendingCount()) return
    for (const resolve of ackWaiters) resolve()
    ackWaiters.clear()
  }

  function sayPresence() {
    if (connected) send(frame(1, Y.encodeAwarenessUpdate(awareness, [clientID])))
  }

  function clearRemotePresence() {
    const remote = [...awareness.getStates().keys()].filter(id => Number(id) !== clientID)
    if (remote.length) Y.removeAwarenessStates(awareness, BigUint64Array.from(remote, BigInt))
  }

  const onDocUpdate = update => {
    if (applyingRemote) stats.remoteUpdates++
    else { stats.localUpdates++; pendingLocal.push(update.slice()) }
    notify(true)
  }
  const onAwareness = () => notify()
  doc.on("update", onDocUpdate)
  awareness.on("update", onAwareness)
  awareness.setLocalState(savedPresence)

  function applyRemoteUpdate(update) {
    checkNoTransaction()
    applyingRemote = true
    try { Y.applyUpdate(doc, update, REMOTE_ORIGIN) }
    finally { applyingRemote = false }
  }

  function receive(message) {
    try {
      if (message && message.ack !== undefined) {
        const before = delivery.pending.length
        delivery.onAck(message.ack)
        if (delivery.pending.length < before) stats.acknowledgments++
        settleAcknowledgments()
        notify()
        return
      }
      const encoded = message?.awareness ?? message?.update
      if (typeof encoded !== "string") return
      const decoded = decodeFrame(fromBase64(encoded))
      if (!decoded) return
      const { type, subtype, payload } = decoded
      if (message.awareness !== undefined && type !== 1) throw new Error("Non-awareness frame on awareness channel")
      if (type === 1) Y.applyAwarenessUpdate(awareness, payload, REMOTE_ORIGIN)
      else if (subtype === 0) {
        if (!connected) openingRequest = payload.slice()
        else send(frame(0, Y.encodeStateAsUpdate(doc, payload), 1))
      } else {
        applyRemoteUpdate(payload)
        if (subtype === 1) {
          synced = true
          if (!everSynced) { everSynced = true; resolveSynced() }
        }
      }
      notify()
    } catch (reason) { failed(reason, "received") }
  }

  function connect() {
    checkNoTransaction()
    if (subscription) return
    error = ""
    const currentGeneration = ++generation
    const current = () => currentGeneration === generation && !destroyed
    // Works with consumers that call their mixin synchronously inside create().
    const run = callback => queueMicrotask(() => { if (current()) callback() })
    subscription = consumer.subscriptions.create({ channel, ...channelParams }, {
      received(message) { run(() => receive(message)) },
      connected() { run(() => {
        connected = true
        synced = false
        error = ""
        try {
          if (openingRequest) send(frame(0, Y.encodeStateAsUpdate(doc, openingRequest), 1))
          openingRequest = null
          send(frame(0, Y.encodeStateVector(doc), 0))
          awareness.setLocalState(savedPresence)
          sayPresence()
          flushLocal()
          delivery.onConnect()
          notify()
        } catch (reason) { failed(reason, "connected") }
      }) },
      disconnected() { run(() => {
        connected = false
        synced = false
        openingRequest = null
        delivery.onDisconnect()
        clearRemotePresence()
        notify()
      }) },
      rejected() { run(() => {
        disconnect()
        failed(new Error("Document subscription was rejected"), "rejected")
      }) },
    })
    if (manageConsumer) consumer.connect?.()
    notify()
  }

  function disconnect() {
    if (destroyed) return
    checkNoTransaction()
    if (connected) { awareness.setLocalState(null); sayPresence() }
    ++generation
    connected = false
    synced = false
    openingRequest = null
    delivery.onDisconnect()
    const previous = subscription
    subscription = null
    // Let the final presence frame flush before removing its subscription.
    queueMicrotask(() => {
      previous?.unsubscribe?.()
      if (manageConsumer && !subscription) consumer.disconnect?.()
    })
    clearRemotePresence()
    awareness.setLocalState(savedPresence)
    notify()
  }

  function mutate(operation) {
    checkAlive()
    if (activeTransaction) return operation(activeTransaction)
    const transaction = doc.beginTransaction(LOCAL_ORIGIN)
    try { return operation(transaction) } finally { transaction.free() }
  }

  function root(kind, name) {
    checkAlive()
    name = String(name)
    const key = `${kind}:${name}`
    if (roots.has(key)) return roots.get(key).handle
    // Creating a root opens its own Yrs transaction. Check rather than allowing
    // a Rust borrow panic to permanently poison the running WASM instance.
    checkNoTransaction()
    if ([...roots.values()].some(entry => entry.name === name && entry.kind !== kind)) {
      throw new TypeError(`Root ${name} already opened with a different type`)
    }
    const native = doc[`get${kind}`](name)
    const readJSON = () => { checkAlive(); return JSON.stringify(native.toJson(activeTransaction ?? undefined)) }
    const length = () => { checkAlive(); return native.length(activeTransaction ?? undefined) }
    const handle = { native, name, kind, readJSON, get length() { return length() } }
    if (kind === "Map") Object.assign(handle, {
      getJSON(key) { checkAlive(); return JSON.stringify(native.get(String(key), activeTransaction ?? undefined) ?? null) },
      has(key) { checkAlive(); return native.get(String(key), activeTransaction ?? undefined) !== undefined },
      setJSON(key, json) { const value = JSON.parse(json); mutate(tx => native.set(String(key), value, tx)) },
      delete(key) { mutate(tx => native.delete(String(key), tx)) },
      keysJSON() { checkAlive(); return JSON.stringify(Object.keys(native.toJson(activeTransaction ?? undefined))) },
    })
    if (kind === "Text") Object.assign(handle, {
      toString() { checkAlive(); return native.toString(activeTransaction ?? undefined) },
      insert(at, text) { index(at, length()); mutate(tx => native.insert(at, String(text), undefined, tx)) },
      delete(at, count) { index(at, length()); index(count, length() - at, "length"); mutate(tx => native.delete(at, count, tx)) },
    })
    if (kind === "Array") Object.assign(handle, {
      getJSON(at) {
        index(at, length())
        return at === length() ? "null" : JSON.stringify(native.get(at, activeTransaction ?? undefined) ?? null)
      },
      insertJSON(at, json) {
        index(at, length())
        const values = JSON.parse(json)
        if (!Array.isArray(values)) throw new TypeError("Array insertion requires a JSON array")
        mutate(tx => native.insert(at, values, tx))
      },
      delete(at, count = 1) { index(at, length()); index(count, length() - at, "length"); mutate(tx => native.delete(at, count, tx)) },
    })
    roots.set(key, { kind, name, native, handle })
    return handle
  }

  function createUndoManager(scope, origin = LOCAL_ORIGIN, captureTimeout = 500) {
    checkNoTransaction()
    if (!Array.isArray(scope) || !scope.length) throw new TypeError("Undo requires at least one shared type")
    if (!Number.isFinite(captureTimeout) || captureTimeout < 0) throw new TypeError("captureTimeout must be nonnegative")
    const types = scope.map(item => typeof item === "string" ? root("Map", item).native : item.native ?? item)
    const native = new Y.YUndoManager({ captureTimeout })
    native.addToScope(types)
    native.addTrackedOrigin(origin)
    const listeners = new Set()
    let closed = false
    let queued = false
    let last = ""
    const manager = {
      native,
      get canUndo() { return !closed && native.canUndo },
      get canRedo() { return !closed && native.canRedo },
      notify() {
        if (closed || queued) return
        queued = true
        queueMicrotask(() => {
          queued = false
          if (closed || destroyed) return
          const state = JSON.stringify({ canUndo: native.canUndo, canRedo: native.canRedo })
          if (state !== last) { last = state; dispatch(listeners, state) }
          notify()
        })
      },
      undo() { checkNoTransaction(); if (closed) throw new Error("Undo manager is destroyed"); native.undo(); manager.notify() },
      redo() { checkNoTransaction(); if (closed) throw new Error("Undo manager is destroyed"); native.redo(); manager.notify() },
      stopCapturing() { checkNoTransaction(); if (!closed) native.stopCapturing() },
      clear() { checkNoTransaction(); if (!closed) { native.clear(); manager.notify() } },
      onChange(callback) { listeners.add(callback); manager.notify(); return () => listeners.delete(callback) },
      destroy() {
        if (closed) return
        checkNoTransaction()
        closed = true
        listeners.clear()
        undoManagers.delete(manager)
        // Yrs owns observer lifetimes; some event names cannot be removed via
        // off() in ywasm 0.28. Free the complete manager exactly once.
        native.free()
      },
    }
    // Observe document updates and our own undo operations, avoiding ywasm
    // 0.28 undo-event closures whose finalizers can trap after manager.free().
    undoManagers.add(manager)
    return manager
  }

  const presenceTimer = setInterval(() => {
    if (destroyed || !connected || activeTransaction) return
    try {
      awareness.setLocalState(savedPresence)
      sayPresence()
      const now = Date.now()
      const stale = [...awareness.meta].filter(([id, meta]) => Number(id) !== clientID &&
        now - meta.last_updated > 30_000 && awareness.getStates().has(id)).map(([id]) => id)
      if (stale.length) Y.removeAwarenessStates(awareness, BigUint64Array.from(stale, BigInt))
    } catch (reason) { failed(reason, "presence") }
  }, 10_000)
  presenceTimer.unref?.()
  const pageHide = () => { restoreAfterPageShow = !!subscription; disconnect() }
  const pageShow = event => { if (event.persisted && restoreAfterPageShow) connect() }
  globalThis.window?.addEventListener("pagehide", pageHide)
  globalThis.window?.addEventListener("pageshow", pageShow)

  return {
    doc, awareness, delivery, consumer, stats, clientID,
    map: name => root("Map", name), text: name => root("Text", name), array: name => root("Array", name),
    createUndoManager,
    beginTransaction(origin = LOCAL_ORIGIN) { checkNoTransaction(); activeTransaction = doc.beginTransaction(origin) },
    endTransaction() {
      checkAlive()
      if (!activeTransaction) throw new Error("No active transaction")
      const previous = activeTransaction
      activeTransaction = null
      previous.free()
    },
    setPresenceJSON(json) {
      checkNoTransaction()
      savedPresence = parsePresence(json)
      awareness.setLocalState(savedPresence)
      sayPresence()
    },
    getPresenceJSON() { checkAlive(); return JSON.stringify(savedPresence) },
    getStatus() { checkAlive(); return status() },
    get status() { return providerStatus() },
    get synced() { return synced },
    get hasPending() { return pendingCount() > 0 },
    get whenSynced() { return whenSynced },
    get whenAcknowledged() {
      if (!pendingCount()) return Promise.resolve()
      return new Promise(resolve => { ackWaiters.add(resolve) })
    },
    get pendingUpdate() {
      checkNoTransaction()
      const updates = [...delivery.pending.map(entry => entry.update), ...pendingLocal]
      return updates.length ? Y.mergeUpdatesV1(updates).slice() : null
    },
    applyRemoteUpdate,
    restorePendingUpdate(update) {
      applyRemoteUpdate(update)
      pendingLocal.push(update.slice())
      notify()
    },
    encodeStateAsUpdate(vector) { checkNoTransaction(); return Y.encodeStateAsUpdate(doc, vector) },
    encodeStateVector() { checkNoTransaction(); return Y.encodeStateVector(doc) },
    connect, disconnect,
    renew(nextParams) { checkAlive(); Object.assign(channelParams, nextParams); disconnect(); connect() },
    onChange(callback) { checkAlive(); changes.add(callback); return () => changes.delete(callback) },
    onStatus(callback) {
      checkAlive()
      statuses.add(callback)
      queueMicrotask(() => { if (!destroyed && statuses.has(callback)) callback(status()) })
      return () => statuses.delete(callback)
    },
    onStatusChange(callback) { checkAlive(); providerStatuses.add(callback); return () => providerStatuses.delete(callback) },
    destroy() {
      if (destroyed) return
      checkNoTransaction()
      disconnect()
      for (const manager of [...undoManagers]) manager.destroy()
      destroyed = true
      clearInterval(presenceTimer)
      globalThis.window?.removeEventListener("pagehide", pageHide)
      globalThis.window?.removeEventListener("pageshow", pageShow)
      changes.clear(); statuses.clear(); providerStatuses.clear(); ackWaiters.clear()
      pendingLocal.length = 0
      delivery.destroy()
      awareness.off("update", onAwareness)
      doc.off("update", onDocUpdate)
      awareness.destroy()
      awareness.free()
      for (const entry of roots.values()) entry.native.free()
      roots.clear()
      doc.destroy()
      doc.free()
    },
  }
}
