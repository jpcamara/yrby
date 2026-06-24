// A batteries-included, transport-agnostic session for the yrb-lite
// y-websocket protocol.
//
// YProtocolSession composes ReliableSync and additionally owns the parts a provider
// would otherwise re-implement: the y-protocols message framing (encode/decode),
// the sync-step handshake (SyncStep1 / SyncStep2 / Update), and awareness
// encode/apply. It binds to a Y.Doc (and optional Awareness) and speaks in raw
// Uint8Array frames -- you bring only the transport: base64 + the
// `{ update, id }` / `{ ack }` envelope and the socket.
//
// Drive it from your transport:
//   onConnect()          -> sends the opening handshake, replays the unacked tail
//   onDisconnect()       -> pauses retransmits, clears remote presence
//   ack(id)              -> a `{ ack: id }` envelope arrived
//   const reply = receive(frame)  -> a binary protocol frame arrived; send `reply` if non-null
// Local document edits and awareness changes are picked up automatically via the
// doc's / awareness's "update" events.
import { Doc, mergeUpdates, applyUpdate } from "yjs";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";
import { readSyncMessage, writeSyncStep1, writeUpdate, messageYjsSyncStep2 } from "y-protocols/sync";
import {
  encodeAwarenessUpdate,
  applyAwarenessUpdate,
  removeAwarenessStates,
  type Awareness,
} from "y-protocols/awareness";
import { readAuthMessage } from "y-protocols/auth";
import { ReliableSync, type TimerHandle } from "./reliable_sync.js";

export const MessageType = { Sync: 0, Awareness: 1, Auth: 2, QueryAwareness: 3 } as const;

export interface YProtocolSessionOptions {
  /**
   * Transmit one raw protocol frame. `id` is set only for reliable document
   * updates (tag it onto your envelope so the server can ack). Awareness frames
   * are identifiable by their first byte (`MessageType.Awareness`) if a transport
   * needs to route them separately.
   */
  send: (frame: Uint8Array, id: number | undefined) => void;
  /** Optional awareness/presence. When omitted, awareness frames are ignored. */
  awareness?: Awareness | null;
  /** Forwarded to ReliableSync. */
  resendInterval?: number;
  /**
   * Called when an incoming frame can't be decoded/applied (malformed bytes,
   * truncated message, unexpected structure). The frame is dropped and the
   * session keeps running. `context` names where it happened (e.g. "receive").
   * Defaults to a `console.warn`.
   */
  onError?: (error: unknown, context: string) => void;
  /** Injectable timer hooks (forwarded to ReliableSync); handy for tests. */
  setInterval?: (handler: () => void, ms: number) => TimerHandle;
  clearInterval?: (handle: TimerHandle) => void;
}

type AwarenessChange = { added: number[]; updated: number[]; removed: number[] };

export class YProtocolSession {
  readonly doc: Doc;
  readonly awareness: Awareness | null;

  #send: YProtocolSessionOptions["send"];
  #onError: (error: unknown, context: string) => void;
  #synced = false;
  #delivery: ReliableSync;
  #onDocUpdate: (update: Uint8Array, origin: unknown) => void;
  #onAwarenessUpdate?: (change: AwarenessChange, origin: unknown) => void;

  constructor(doc: Doc, opts: YProtocolSessionOptions) {
    const {
      send,
      awareness = null,
      resendInterval,
      onError,
      setInterval: setIntervalFn,
      clearInterval: clearIntervalFn,
    } = opts ?? ({} as YProtocolSessionOptions);
    if (!doc) throw new TypeError("YProtocolSession requires a Y.Doc");
    if (typeof send !== "function") throw new TypeError("YProtocolSession requires a send(frame, id) function");

    this.doc = doc;
    this.awareness = awareness;
    this.#send = send;
    this.#onError = onError ?? ((error, context) => console.warn(`[yrb-lite] ${context}:`, error));

    this.#delivery = new ReliableSync({
      merge: mergeUpdates,
      send: (update, id) => this.#send(this.#frameUpdate(update), id),
      resendInterval,
      setInterval: setIntervalFn,
      clearInterval: clearIntervalFn,
    });

    this.#onDocUpdate = (update: Uint8Array, origin: unknown) => {
      if (origin === this) return; // applied from the server; don't echo it back
      this.#delivery.enqueue(update);
    };
    this.doc.on("update", this.#onDocUpdate);

    if (this.awareness) {
      this.#onAwarenessUpdate = ({ added, updated, removed }: AwarenessChange, origin: unknown) => {
        // Only broadcast OUR OWN presence changes (origin "local"). Updates we
        // applied from a peer -- and our own remote-cleanup in onDisconnect --
        // carry origin === this; re-sending those would echo presence and
        // broadcast tombstones for other clients' cursors.
        if (origin === this) return;
        const changed = added.concat(updated, removed);
        this.#send(this.#frameAwareness(changed), undefined); // fire-and-forget
      };
      this.awareness.on("update", this.#onAwarenessUpdate);
    }
  }

  /** True once we've received the server's SyncStep2 (the document is caught up). */
  get synced(): boolean {
    return this.#synced;
  }

  /** True while there are unacknowledged local document updates in flight. */
  get hasPending(): boolean {
    return this.#delivery.hasPending;
  }

  /** Transport connected: send the opening handshake and replay the unacked tail. */
  onConnect(): void {
    this.#send(this.#frameSyncStep1(), undefined);
    if (this.awareness && this.awareness.getLocalState() !== null) {
      this.#send(this.#frameAwareness([this.doc.clientID]), undefined);
    }
    this.#delivery.onConnect();
  }

  /** Transport dropped: pause retransmits (queue kept) and clear remote presence. */
  onDisconnect(): void {
    this.#synced = false;
    this.#delivery.onDisconnect();
    if (this.awareness) {
      const remote = [...this.awareness.getStates().keys()].filter((c) => c !== this.doc.clientID);
      if (remote.length) removeAwarenessStates(this.awareness, remote, this);
    }
  }

  /**
   * Broadcast that our local presence is gone (sets local state to null, which
   * emits a removal awareness frame through `send`). Call this while the
   * transport is still live so peers drop our cursor immediately instead of
   * waiting for the awareness timeout. A no-op when there's no local state.
   */
  removeLocalAwareness(): void {
    if (this.awareness && this.awareness.getLocalState() !== null) {
      this.awareness.setLocalState(null); // fires "update" -> sends the removal frame
    }
  }

  /** A reliable-delivery `{ ack: id }` envelope arrived. */
  ack(id: number): void {
    this.#delivery.onAck(id);
  }

  /**
   * Apply an update to the document WITHOUT treating it as a local edit -- i.e.
   * without queueing it for reliable re-delivery to the server. Use this for
   * bootstrap/restore flows where the bytes are already-durable document state
   * the server already has: initial state loaded over HTTP, a server snapshot, an
   * import or restore.
   *
   * The session re-sends every doc update whose origin isn't itself (that's how a
   * local keystroke becomes an outbound reliable frame). Applying bootstrap bytes
   * with a bare `Y.applyUpdate(doc, update)` therefore looks exactly like a local
   * edit and gets re-sent on the next connect -- echoing the whole initial state
   * back as a "pending" change. Routing them through here applies them under the
   * session's own origin, which the outbound filter skips. Safe to call before
   * `onConnect()`: the bootstrapped state is folded into the SyncStep1 handshake
   * (the server sees we already have it) instead of being re-sent.
   */
  applyRemoteUpdate(update: Uint8Array): void {
    applyUpdate(this.doc, update, this);
  }

  /**
   * Decode and apply one incoming binary protocol frame (document sync, awareness,
   * query, or auth). Returns a reply frame to transmit (e.g. SyncStep2 answering a
   * SyncStep1, or an awareness reply to a query), or null if there's nothing to send.
   */
  receive(frame: Uint8Array): Uint8Array | null {
    // A malformed/truncated frame must never take down the transport callback:
    // decode + apply defensively, drop the frame on error, keep the session live.
    try {
      const validatedType = this.#validateFrame(frame);
      if (validatedType === null) return null;

      const decoder = decoding.createDecoder(frame);
      const encoder = encoding.createEncoder();
      const type = decoding.readVarUint(decoder);
      switch (type) {
        case MessageType.Sync: {
          encoding.writeVarUint(encoder, MessageType.Sync);
          const syncType = readSyncMessage(decoder, encoder, this.doc, this);
          if (!this.#synced && syncType === messageYjsSyncStep2) this.#synced = true;
          break;
        }
        case MessageType.Awareness:
          if (this.awareness) applyAwarenessUpdate(this.awareness, decoding.readVarUint8Array(decoder), this);
          break;
        case MessageType.QueryAwareness:
          if (this.awareness) {
            encoding.writeVarUint(encoder, MessageType.Awareness);
            encoding.writeVarUint8Array(
              encoder,
              encodeAwarenessUpdate(this.awareness, [...this.awareness.getStates().keys()])
            );
          }
          break;
        case MessageType.Auth:
          readAuthMessage(decoder, this.doc, (_doc, reason) => console.warn(`[yrb-lite] auth denied: ${reason}`));
          break;
        default:
          return null; // unknown message type: ignore
      }
      return encoding.length(encoder) > 1 ? encoding.toUint8Array(encoder) : null;
    } catch (error) {
      this.#onError(error, "receive");
      return null;
    }
  }

  /** Detach doc/awareness listeners and stop retransmits. */
  destroy(): void {
    this.doc.off("update", this.#onDocUpdate);
    if (this.awareness && this.#onAwarenessUpdate) this.awareness.off("update", this.#onAwarenessUpdate);
    this.#delivery.destroy();
  }

  #frameSyncStep1(): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Sync);
    writeSyncStep1(e, this.doc);
    return encoding.toUint8Array(e);
  }

  #frameUpdate(update: Uint8Array): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Sync);
    writeUpdate(e, update);
    return encoding.toUint8Array(e);
  }

  #frameAwareness(clients: number[]): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Awareness);
    encoding.writeVarUint8Array(e, encodeAwarenessUpdate(this.awareness as Awareness, clients));
    return encoding.toUint8Array(e);
  }

  #validateFrame(frame: Uint8Array): number | null {
    const decoder = decoding.createDecoder(frame);
    const type = decoding.readVarUint(decoder);
    switch (type) {
      case MessageType.Sync: {
        const scratchDoc = new Doc();
        try {
          const scratchEncoder = encoding.createEncoder();
          encoding.writeVarUint(scratchEncoder, MessageType.Sync);
          readSyncMessage(decoder, scratchEncoder, scratchDoc, this);
        } finally {
          scratchDoc.destroy();
        }
        break;
      }
      case MessageType.Awareness:
        decoding.readVarUint8Array(decoder);
        break;
      case MessageType.QueryAwareness:
        break;
      case MessageType.Auth: {
        const scratchDoc = new Doc();
        try {
          readAuthMessage(decoder, scratchDoc, () => {});
        } finally {
          scratchDoc.destroy();
        }
        break;
      }
      default:
        return null; // unknown message type: ignore
    }
    // This protocol is one message per frame. Anything left after a complete
    // message is malformed (trailing garbage, or low-level packed messages
    // whose tail we'd silently drop) -- reject before mutating local state.
    if (decoding.hasContent(decoder)) {
      throw new Error("frame has trailing bytes after a complete message");
    }
    return type;
  }
}
