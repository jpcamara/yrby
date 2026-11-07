// A CableConsumer over a binary y-protocols WebSocket, for servers that speak
// the protocol directly (AnyCable's yjs endpoint). Hand it to
// ActionCableProvider in place of an Action Cable consumer:
//
//   const consumer = createBinaryConsumer("wss://example.com/yjs/");
//   new ActionCableProvider(doc, consumer, "DocumentChannel", { id, grant });
//
// Each subscription opens its own socket, since a binary frame names no
// document. The first frame is a y-protocols auth message carrying the
// channel identifier, so a signed grant travels inside the socket instead of
// the URL. Reliable updates go out as [100][id][frame] and come back acked as
// [101][id]. Everything else is a plain y-protocols frame, except the
// channel's own messages, which arrive as JSON text frames.
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import { toBase64, fromBase64 } from "./base64.js";
import type { CableConsumer, CableSubscription } from "./actioncable_provider.js";

const MessageAuth = 2;
const AuthToken = 1;
const MessageUpdate = 100;
const MessageAck = 101;

/** The server closes with this code when it refuses the connection or subscription. */
export const CloseUnauthorized = 4403;

// The server pings every few seconds. A socket silent for longer than this is
// treated as dead and reopened, as Action Cable's connection monitor does.
const STALE_AFTER_MS = 10_000;
const RECONNECT_DELAYS_MS = [500, 1_000, 2_000, 5_000, 10_000];

interface Handlers {
  received?(message: unknown): void;
  connected?(): void;
  disconnected?(): void;
  rejected?(): void;
}

export interface BinaryConsumerOptions {
  /** A WebSocket constructor, for runtimes without a global one. */
  WebSocket?: typeof WebSocket;
}

export function createBinaryConsumer(url: string, opts: BinaryConsumerOptions = {}): CableConsumer {
  return {
    subscriptions: {
      create(identifier: string | object, handlers: Handlers = {}): CableSubscription {
        const params = typeof identifier === "string" ? { channel: identifier } : identifier;
        return new BinarySubscription(url, JSON.stringify(params), handlers, opts.WebSocket ?? WebSocket);
      },
    },
  };
}

class BinarySubscription implements CableSubscription {
  #socket: WebSocket | null = null;
  #stopped = false;
  #attempts = 0;
  #reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  #staleTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    readonly url: string,
    readonly identifier: string,
    readonly handlers: Handlers,
    readonly Socket: typeof WebSocket,
  ) {
    this.#open();
  }

  send(data: { update?: string; id?: number }): boolean {
    if (typeof data?.update !== "string") return false;
    const frame = fromBase64(data.update);
    if (data.id === undefined) return this.#write(frame);
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageUpdate);
    encoding.writeVarUint(e, data.id);
    encoding.writeUint8Array(e, frame);
    return this.#write(encoding.toUint8Array(e));
  }

  whisper(data: { awareness?: string }): boolean {
    return typeof data?.awareness === "string" && this.#write(fromBase64(data.awareness));
  }

  unsubscribe(): void {
    this.#stopped = true;
    clearTimeout(this.#reconnectTimer);
    clearTimeout(this.#staleTimer);
    this.#socket?.close(1000);
    this.#socket = null;
  }

  #open(): void {
    const socket = new this.Socket(this.url);
    socket.binaryType = "arraybuffer";
    this.#socket = socket;

    socket.onopen = () => {
      if (this.#socket !== socket) return;
      const e = encoding.createEncoder();
      encoding.writeVarUint(e, MessageAuth);
      encoding.writeVarUint(e, AuthToken);
      encoding.writeVarString(e, this.identifier);
      socket.send(encoding.toUint8Array(e));
      // The server subscribes before it reads the next frame, so the
      // provider's opening handshake can follow right away.
      this.#attempts = 0;
      this.#touch();
      this.handlers.connected?.();
    };

    socket.onmessage = (event: MessageEvent) => {
      if (this.#socket !== socket) return;
      this.#touch();
      // Text frames carry the channel's own JSON messages, which have no
      // y-protocols form.
      const message = event.data instanceof ArrayBuffer ? decode(new Uint8Array(event.data)) : parseJSON(event.data);
      this.handlers.received?.(message);
    };

    socket.onclose = (event: CloseEvent) => {
      if (this.#socket !== socket) return;
      this.#socket = null;
      clearTimeout(this.#staleTimer);
      if (this.#stopped) return;
      if (event.code === CloseUnauthorized) {
        this.#stopped = true;
        this.handlers.rejected?.();
        return;
      }
      this.handlers.disconnected?.();
      const delay = RECONNECT_DELAYS_MS[Math.min(this.#attempts++, RECONNECT_DELAYS_MS.length - 1)];
      this.#reconnectTimer = setTimeout(() => { if (!this.#stopped) this.#open(); }, delay);
    };
  }

  #write(frame: Uint8Array): boolean {
    const socket = this.#socket;
    if (!socket || socket.readyState !== this.Socket.OPEN) return false;
    socket.send(frame);
    return true;
  }

  #touch(): void {
    clearTimeout(this.#staleTimer);
    const socket = this.#socket;
    this.#staleTimer = setTimeout(() => { if (this.#socket === socket) socket?.close(); }, STALE_AFTER_MS);
  }
}

// Shape incoming frames like the Action Cable envelope the provider reads.
function decode(frame: Uint8Array): { update: string } | { ack: number } | null {
  if (frame[0] !== MessageAck) return { update: toBase64(frame) };
  try {
    const d = decoding.createDecoder(frame.subarray(1));
    return { ack: decoding.readVarUint(d) };
  } catch {
    return null;
  }
}

function parseJSON(data: unknown): unknown {
  try {
    return JSON.parse(String(data));
  } catch {
    return null;
  }
}
