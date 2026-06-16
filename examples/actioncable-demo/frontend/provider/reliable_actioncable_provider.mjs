// The @y-rb/actioncable WebsocketProvider, vendored and augmented with
// yrb-lite's reliable-delivery layer. Everything below the marked sections is
// upstream (detranspiled from dist/actioncable.esm.js, v0.3.x); the additions
// give "no acknowledged edit is ever silently lost" without changing the wire
// protocol or the `{ update: ... }` envelope, so it stays a drop-in replacement.
//
// How it works (document updates only):
//   * Each outgoing batch carries an "id". yrb-lite replies `{ ack: <id> }` once
//     it has *accepted* the update (recorded in audit mode, applied in fast
//     mode). A causally-gapped update is not acked -- it gets a resync.
//   * "Sync since last ack": unacknowledged local updates are kept in a queue
//     and sent as their MERGE -- one causally-complete delta -- so the server
//     never sees an internal gap. The id is the highest sequence in the batch,
//     so a single ack cumulatively confirms everything up to it.
//   * Retransmit on a timer and on reconnect until the ack lands; idempotent
//     CRDT apply makes resends free.
//
// Awareness/presence stays fire-and-forget (ephemeral, no point acking).
// Against a server that doesn't implement acks the provider warns once and
// falls back to plain delivery. `reliable: false` opts out entirely.
import { writeVarUint, writeVarUint8Array, createEncoder, length, toUint8Array } from "lib0/encoding"
import { readVarUint8Array, createDecoder, readVarUint } from "lib0/decoding"
import {
  readSyncMessage,
  messageYjsSyncStep2,
  writeSyncStep1,
  writeSyncStep2,
  writeUpdate,
} from "y-protocols/sync"
import {
  encodeAwarenessUpdate,
  applyAwarenessUpdate,
  removeAwarenessStates,
  Awareness,
} from "y-protocols/awareness"
import { readAuthMessage } from "y-protocols/auth"
import { publish, subscribe, unsubscribe } from "lib0/broadcastchannel"
import * as Y from "yjs" // [reliable] mergeUpdates for sync-since-last-ack

const MessageType = { Sync: 0, Awareness: 1, Auth: 2, QueryAwareness: 3 }

const permissionDeniedHandler = (provider, reason) =>
  console.warn(`Permission denied to access ${provider.channelName}.\n${reason}`)

const messageHandlers = {
  [MessageType.Sync]: (encoder, decoder, provider, emitSynced) => {
    writeVarUint(encoder, MessageType.Sync)
    const syncMessageType = readSyncMessage(decoder, encoder, provider.doc, provider)
    if (emitSynced && syncMessageType === messageYjsSyncStep2 && !provider.synced) {
      provider.synced = true
    }
  },
  [MessageType.QueryAwareness]: (encoder, _decoder, provider) => {
    writeVarUint(encoder, MessageType.Awareness)
    writeVarUint8Array(
      encoder,
      encodeAwarenessUpdate(provider.awareness, Array.from(provider.awareness.getStates().keys()))
    )
  },
  [MessageType.Awareness]: (_encoder, decoder, provider) => {
    applyAwarenessUpdate(provider.awareness, readVarUint8Array(decoder), provider)
  },
  [MessageType.Auth]: (_encoder, decoder, provider) => {
    readAuthMessage(decoder, provider.doc, (_ydoc, reason) => permissionDeniedHandler(provider, reason))
  },
}

export class WebsocketProvider {
  constructor(
    doc,
    consumer,
    channel,
    params,
    {
      awareness = new Awareness(doc),
      disableBc = false,
      // [reliable] opt-in delivery guarantee (on by default).
      reliable = true,
      resendInterval = 1000,
      maxUnconfirmedResends = 8,
    } = {}
  ) {
    this.consumer = consumer
    this.channel = undefined
    this.params = params
    this.doc = doc
    this.channelName = channel
    this.bcChannelName = `${channel}_${Object.entries(params).map((k, v) => `${k}-${v}`).join("_")}`
    this.awareness = awareness
    this.bcconnected = false
    this.disableBc = disableBc
    this._synced = false

    // [reliable] delivery state.
    this.reliable = reliable
    this.resendInterval = resendInterval
    this.maxUnconfirmedResends = maxUnconfirmedResends
    this.pending = [] // unacked local updates: [{ seq, update }], in order
    this.nextSeq = 1
    this.everAcked = false
    this._resendsSinceProgress = 0
    this._serverConnected = false
    this._resendTimer = undefined

    this.bcSubscriber = (data, origin) => {
      if (origin !== this) {
        const encoder = this.process(new Uint8Array(data), false)
        if (length(encoder) > 1) publish(this.bcChannelName, toUint8Array(encoder), this)
      }
    }
    this.updateHandler = (update, origin) => {
      if (origin !== this) {
        // [reliable] queue the local update and send the merged unacked tail;
        // otherwise behave like upstream (one fire-and-forget Sync/Update).
        if (this.reliable) {
          this.pending.push({ seq: this.nextSeq++, update })
          this.flushToServer()
        } else {
          const encoder = createEncoder()
          writeVarUint(encoder, MessageType.Sync)
          writeUpdate(encoder, update)
          this.send(toUint8Array(encoder))
        }
      }
    }
    this.unloadHandler = () => {
      removeAwarenessStates(this.awareness, [this.doc.clientID], "window unload")
    }
    this.awarenessUpdateHandler = ({ added, updated, removed }) => {
      const changedClients = added.concat(updated).concat(removed)
      const encoder = createEncoder()
      writeVarUint(encoder, MessageType.Awareness)
      writeVarUint8Array(encoder, encodeAwarenessUpdate(this.awareness, changedClients))
      this.send(toUint8Array(encoder), { whisper: true })
    }

    this.doc.on("update", this.updateHandler)
    if (typeof window !== "undefined") window.addEventListener("unload", this.unloadHandler)
    else if (typeof process !== "undefined") process.on("exit", this.unloadHandler)
    this.awareness.on("update", this.awarenessUpdateHandler)

    this.connect()
  }

  get synced() {
    return this._synced
  }

  set synced(state) {
    if (this._synced !== state) this._synced = state
  }

  destroy() {
    this.disconnect()
    if (typeof window !== "undefined") window.removeEventListener("unload", this.unloadHandler)
    else if (typeof process !== "undefined") process.off("exit", this.unloadHandler)
    this.awareness.off("update", this.awarenessUpdateHandler)
    this.doc.off("update", this.updateHandler)
  }

  send(buffer, { whisper = false, id = undefined } = {}) {
    const update = encodeBinaryToBase64(buffer)
    // [reliable] include the batch id when present so the server can ack it.
    const payload = id === undefined ? { update } : { update, id }
    if (whisper && hasWhisper(this.channel)) this.channel.whisper(payload)
    else this.channel?.send(payload)
    if (this.bcconnected) publish(this.bcChannelName, buffer, this)
  }

  // [reliable] Send the whole unacked tail as one merged delta (sync since last
  // ack). The id is the highest queued sequence, so one ack confirms the batch.
  flushToServer() {
    if (this.pending.length === 0) return
    const merged = Y.mergeUpdates(this.pending.map((p) => p.update))
    const id = this.pending[this.pending.length - 1].seq
    const encoder = createEncoder()
    writeVarUint(encoder, MessageType.Sync)
    writeUpdate(encoder, merged)
    this.send(toUint8Array(encoder), { id })
  }

  // [reliable] A `{ ack: id }` cumulatively confirms every queued update <= id.
  onAck(id) {
    this.everAcked = true
    this._resendsSinceProgress = 0
    this.pending = this.pending.filter((p) => p.seq > id)
  }

  // [reliable] Periodic resend of the unacked tail while connected. The first
  // round-trip sets everAcked; if we keep resending on a live connection and
  // never get an ack, the server doesn't support them, so warn once and fall
  // back to fire-and-forget rather than loop forever.
  onResendTick() {
    if (!this._serverConnected || this.pending.length === 0) return
    if (!this.everAcked && ++this._resendsSinceProgress > this.maxUnconfirmedResends) {
      console.warn(
        `[reliable] no acks from ${this.channelName} after ${this.maxUnconfirmedResends} ` +
          "resends; server appears not to support reliable delivery. Falling back."
      )
      this.reliable = false
      this.pending = []
      this.stopResendTimer()
      return
    }
    this.flushToServer()
  }

  startResendTimer() {
    if (this._resendTimer || !this.reliable) return
    this._resendTimer = setInterval(() => this.onResendTick(), this.resendInterval)
    if (typeof this._resendTimer?.unref === "function") this._resendTimer.unref()
  }

  stopResendTimer() {
    if (this._resendTimer) clearInterval(this._resendTimer)
    this._resendTimer = undefined
  }

  process(buffer, emitSynced) {
    const decoder = createDecoder(buffer)
    const encoder = createEncoder()
    const messageType = readVarUint(decoder)
    const messageHandler = messageHandlers[messageType]
    if (messageHandler) messageHandler(encoder, decoder, this, emitSynced, messageType)
    else console.error("Unable to compute message")
    return encoder
  }

  subscribe() {
    const provider = this
    this.synced = false
    this.channel = this.consumer.subscriptions.create(
      { channel: this.channelName, ...this.params },
      {
        received(message) {
          // [reliable] a delivery ack confirms and prunes the local queue.
          if (message?.ack !== undefined) {
            provider.onAck(message.ack)
            return
          }
          const encodedUpdate = message.update
          const update = decodeBase64ToBinary(encodedUpdate)
          const encoder = provider.process(update, true)
          if (length(encoder) > 1) provider.send(toUint8Array(encoder))
        },
        disconnected() {
          provider.synced = false
          provider._serverConnected = false // [reliable]
          provider.stopResendTimer() // [reliable] (queue is kept for reconnect)
          // update awareness (all users except local left)
          removeAwarenessStates(
            provider.awareness,
            Array.from(provider.awareness.getStates().keys()).filter((client) => client !== provider.doc.clientID),
            provider
          )
        },
        connected() {
          provider._serverConnected = true // [reliable]
          // always send sync step 1 when connected
          const encoder = createEncoder()
          writeVarUint(encoder, MessageType.Sync)
          writeSyncStep1(encoder, provider.doc)
          provider.send(toUint8Array(encoder))
          // broadcast local awareness state
          if (provider.awareness.getLocalState() !== null) {
            const encoderAwarenessState = createEncoder()
            writeVarUint(encoderAwarenessState, MessageType.Awareness)
            writeVarUint8Array(
              encoderAwarenessState,
              encodeAwarenessUpdate(provider.awareness, [provider.doc.clientID])
            )
            provider.send(toUint8Array(encoderAwarenessState))
          }
          // [reliable] resend any unacked tail and (re)start the resend timer.
          provider.flushToServer()
          provider.startResendTimer()
        },
      }
    )
  }

  connectBc() {
    if (this.disableBc) return
    if (!this.bcconnected) {
      subscribe(this.bcChannelName, this.bcSubscriber)
      this.bcconnected = true
    }
    // send sync step 1 to bc
    const encoderSync = createEncoder()
    writeVarUint(encoderSync, MessageType.Sync)
    writeSyncStep1(encoderSync, this.doc)
    publish(this.bcChannelName, toUint8Array(encoderSync), this)
    // broadcast local state
    const encoderState = createEncoder()
    writeVarUint(encoderState, MessageType.Sync)
    writeSyncStep2(encoderState, this.doc)
    publish(this.bcChannelName, toUint8Array(encoderState), this)
    // write queryAwareness
    const encoderAwarenessQuery = createEncoder()
    writeVarUint(encoderAwarenessQuery, MessageType.QueryAwareness)
    publish(this.bcChannelName, toUint8Array(encoderAwarenessQuery), this)
    // broadcast local awareness state
    const encoderAwarenessState = createEncoder()
    writeVarUint(encoderAwarenessState, MessageType.Awareness)
    writeVarUint8Array(encoderAwarenessState, encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
    publish(this.bcChannelName, toUint8Array(encoderAwarenessState), this)
  }

  disconnectBc() {
    // broadcast message with local awareness state set to null (indicating disconnect)
    const encoder = createEncoder()
    writeVarUint(encoder, MessageType.Awareness)
    writeVarUint8Array(encoder, encodeAwarenessUpdate(this.awareness, [this.doc.clientID], new Map()))
    this.send(toUint8Array(encoder))
    if (this.bcconnected) {
      unsubscribe(this.bcChannelName, this.bcSubscriber)
      this.bcconnected = false
    }
  }

  disconnect() {
    this.stopResendTimer() // [reliable]
    this._serverConnected = false // [reliable]
    this.disconnectBc()
    this.channel?.unsubscribe()
    if (this.channel != null) this.channel = undefined
  }

  connect() {
    if (this.channel == null) {
      this.subscribe()
      this.connectBc()
    }
  }
}

function encodeBinaryToBase64(bin) {
  return btoa(Array.from(bin, (ch) => String.fromCharCode(ch)).join(""))
}

function decodeBase64ToBinary(update) {
  return Uint8Array.from(atob(update), (c) => c.charCodeAt(0))
}

function hasWhisper(channel) {
  return channel !== undefined && "whisper" in channel && typeof channel.whisper === "function"
}

// [reliable] Preferred name for the augmented provider. `WebsocketProvider`
// stays exported so it remains a drop-in for code importing the upstream name.
export { WebsocketProvider as ReliableActionCableProvider }
