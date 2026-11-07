// A copy of yrby-client's createBinaryConsumer (branch binary-socket), kept
// here until yrby-client ships it. It gives ActionCableProvider a raw binary
// y-protocols WebSocket in place of an Action Cable consumer, served by
// AnyCable's yjs endpoint at /yjs/.
//
// Each subscription opens its own socket. The first frame is a y-protocols
// auth message carrying the channel identifier, so the signed grant travels
// inside the socket instead of the URL. Reliable updates go out as
// [100][id][frame] and come back acked as [101][id]. The channel's own JSON
// messages, like the room-full notice, arrive as text frames.
import * as encoding from "lib0/encoding"
import * as decoding from "lib0/decoding"
import { toBase64, fromBase64 } from "yrby-client"

const MessageAuth = 2
const AuthToken = 1
const MessageUpdate = 100
const MessageAck = 101
const CloseUnauthorized = 4403

// The server pings every few seconds. A socket silent for longer than this is
// treated as dead and reopened, as Action Cable's connection monitor does.
const STALE_AFTER_MS = 10_000
const RECONNECT_DELAYS_MS = [500, 1_000, 2_000, 5_000, 10_000]

export function createBinaryConsumer(url) {
  return {
    subscriptions: {
      create(identifier, handlers = {}) {
        const params = typeof identifier === "string" ? { channel: identifier } : identifier
        return new BinarySubscription(url, JSON.stringify(params), handlers)
      },
    },
  }
}

class BinarySubscription {
  #socket = null
  #stopped = false
  #attempts = 0
  #reconnectTimer
  #staleTimer

  constructor(url, identifier, handlers) {
    this.url = url
    this.identifier = identifier
    this.handlers = handlers
    this.#open()
  }

  send(data) {
    if (typeof data?.update !== "string") return false
    const frame = fromBase64(data.update)
    if (data.id === undefined) return this.#write(frame)
    const e = encoding.createEncoder()
    encoding.writeVarUint(e, MessageUpdate)
    encoding.writeVarUint(e, data.id)
    encoding.writeUint8Array(e, frame)
    return this.#write(encoding.toUint8Array(e))
  }

  whisper(data) {
    return typeof data?.awareness === "string" && this.#write(fromBase64(data.awareness))
  }

  unsubscribe() {
    this.#stopped = true
    clearTimeout(this.#reconnectTimer)
    clearTimeout(this.#staleTimer)
    this.#socket?.close(1000)
    this.#socket = null
  }

  #open() {
    const socket = new WebSocket(this.url)
    socket.binaryType = "arraybuffer"
    this.#socket = socket

    socket.onopen = () => {
      if (this.#socket !== socket) return
      const e = encoding.createEncoder()
      encoding.writeVarUint(e, MessageAuth)
      encoding.writeVarUint(e, AuthToken)
      encoding.writeVarString(e, this.identifier)
      socket.send(encoding.toUint8Array(e))
      // The server subscribes before it reads the next frame, so the
      // provider's opening handshake can follow right away.
      this.#attempts = 0
      this.#touch()
      this.handlers.connected?.()
    }

    socket.onmessage = (event) => {
      if (this.#socket !== socket) return
      this.#touch()
      const message = event.data instanceof ArrayBuffer ? decode(new Uint8Array(event.data)) : parseJSON(event.data)
      this.handlers.received?.(message)
    }

    socket.onclose = (event) => {
      if (this.#socket !== socket) return
      this.#socket = null
      clearTimeout(this.#staleTimer)
      if (this.#stopped) return
      if (event.code === CloseUnauthorized) {
        this.#stopped = true
        this.handlers.rejected?.()
        return
      }
      this.handlers.disconnected?.()
      const delay = RECONNECT_DELAYS_MS[Math.min(this.#attempts++, RECONNECT_DELAYS_MS.length - 1)]
      this.#reconnectTimer = setTimeout(() => { if (!this.#stopped) this.#open() }, delay)
    }
  }

  #write(frame) {
    const socket = this.#socket
    if (!socket || socket.readyState !== WebSocket.OPEN) return false
    socket.send(frame)
    return true
  }

  #touch() {
    clearTimeout(this.#staleTimer)
    const socket = this.#socket
    this.#staleTimer = setTimeout(() => { if (this.#socket === socket) socket?.close() }, STALE_AFTER_MS)
  }
}

// Shape incoming frames like the Action Cable envelope the provider reads.
function decode(frame) {
  if (frame[0] !== MessageAck) return { update: toBase64(frame) }
  try {
    return { ack: decoding.readVarUint(decoding.createDecoder(frame.subarray(1))) }
  } catch {
    return null
  }
}

function parseJSON(data) {
  try {
    return JSON.parse(String(data))
  } catch {
    return null
  }
}
