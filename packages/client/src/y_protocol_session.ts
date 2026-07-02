// Transport-agnostic session for the yrby y-websocket protocol. Handles the
// y-protocols framing, the sync handshake (SyncStep1/Step2/Update), and awareness
// encode/apply on top of ReliableSync. Bind it to a Y.Doc (and an optional
// Awareness); it works in raw Uint8Array frames and leaves the transport to the
// caller: base64, the { update, id } / { ack } envelope, and a socket.
//
// Call onConnect() when the transport connects, onDisconnect() when it drops,
// ack(id) on an { ack } envelope, and receive(frame) for an inbound frame (it
// returns a reply to send, or null). Local doc and awareness edits send
// themselves via the "update" events.
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
import { ReliableSync, type TimerHandle } from "./reliable_sync.js";

// The y-protocols frame types yrby speaks, as the leading byte of a frame.
// Other y-protocols types (auth = 2, query-awareness = 3) are not handled.
export const MessageType = { Sync: 0, Awareness: 1 } as const;

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
    this.#onError = onError ?? ((error, context) => console.warn(`[yrby] ${context}:`, error));

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
        // Only broadcast our own presence changes. Updates applied from a peer,
        // and our own remote-cleanup in onDisconnect, carry origin === this;
        // re-sending those would echo presence and broadcast tombstones for
        // other clients' cursors.
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

  /**
   * A reliable-delivery `{ ack: id }` envelope arrived. `dropped` is set when
   * the server settled the update WITHOUT recording it (rejected as an
   * unhealable causal gap after repeated resyncs). The queue is pruned either
   * way — retransmitting an unhealable update would loop forever — but a
   * dropped settle is surfaced via onError ("ack-dropped") so the app can warn
   * or reload instead of silently reporting synced over lost data.
   */
  ack(id: number, dropped = false): void {
    this.#delivery.onAck(id);
    if (dropped) {
      this.#onError(
        new Error(`server dropped update ${id} as an unhealable causal gap; it was settled but NOT recorded`),
        "ack-dropped"
      );
    }
  }

  /**
   * Apply an update without treating it as a local edit, so it isn't queued for
   * re-delivery to the server. Use it for bootstrap/restore: initial state loaded
   * over HTTP, a server snapshot, an import. These are bytes the server already
   * has.
   *
   * The session re-sends any doc update whose origin isn't itself (that's how a
   * keystroke becomes an outbound frame), so a bare `Y.applyUpdate(doc, update)`
   * would look like a local edit and get echoed back on the next connect. Going
   * through here applies under the session's own origin, which the outbound
   * filter skips. Safe to call before `onConnect()`: the state folds into the
   * SyncStep1 handshake instead of being re-sent.
   */
  applyRemoteUpdate(update: Uint8Array): void {
    applyUpdate(this.doc, update, this);
  }

  /**
   * Decode and apply one incoming binary protocol frame (document sync or
   * awareness). Returns a reply frame to transmit (e.g. SyncStep2 answering a
   * SyncStep1), or null if there's nothing to send.
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
        default:
          return null; // a y-protocols type yrby doesn't speak (auth, query-awareness): ignore
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
        // Validate the payload's CONTENTS, not just the envelope.
        // applyAwarenessUpdate mutates state entry by entry and only notifies
        // listeners at the end — a bad entry mid-payload would leave earlier
        // entries applied with no event fired. Dry-running every entry here
        // makes the real apply infallible (and catches trailing garbage
        // inside the blob).
        {
          const payload = decoding.readVarUint8Array(decoder);
          const inner = decoding.createDecoder(payload);
          const count = decoding.readVarUint(inner);
          for (let i = 0; i < count; i++) {
            decoding.readVarUint(inner); // clientID
            decoding.readVarUint(inner); // clock
            JSON.parse(decoding.readVarString(inner)); // state (null on removal)
          }
          if (decoding.hasContent(inner)) {
            throw new Error("awareness payload has trailing bytes");
          }
        }
        break;
      default:
        return null; // a y-protocols type yrby doesn't speak: ignore
    }
    // This protocol is one message per frame. Anything left after a complete
    // message is malformed (trailing garbage, or low-level packed messages whose
    // tail we'd silently drop), so reject it before mutating local state.
    if (decoding.hasContent(decoder)) {
      throw new Error("frame has trailing bytes after a complete message");
    }
    return type;
  }
}
