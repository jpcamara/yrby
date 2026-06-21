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
import { mergeUpdates, type Doc } from "yjs";
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

/** Hints about an outgoing frame, so the transport can route it appropriately. */
export interface SendOptions {
  /**
   * True for awareness/presence frames. These are ephemeral and fire-and-forget,
   * so a transport that supports it (e.g. AnyCable `whisper`) can broadcast them
   * client-to-client without a server round-trip. Transports without that just
   * send normally.
   */
  awareness?: boolean;
}

export interface YProtocolSessionOptions {
  /**
   * Transmit one raw protocol frame. `id` is set only for reliable document
   * updates (tag it onto your envelope so the server can ack). `opts.awareness`
   * marks presence frames so the transport can whisper them where supported.
   */
  send: (frame: Uint8Array, id: number | undefined, opts?: SendOptions) => void;
  /** Optional awareness/presence. When omitted, awareness frames are ignored. */
  awareness?: Awareness | null;
  /** Use ack-tracked reliable delivery (default true). */
  reliable?: boolean;
  /** Forwarded to ReliableSync. */
  resendInterval?: number;
  /** Forwarded to ReliableSync. */
  maxUnconfirmedResends?: number;
  /** Forwarded to ReliableSync. */
  onFallback?: () => void;
  /** Injectable timer hooks (forwarded to ReliableSync); handy for tests. */
  setInterval?: (handler: () => void, ms: number) => TimerHandle;
  clearInterval?: (handle: TimerHandle) => void;
}

type AwarenessChange = { added: number[]; updated: number[]; removed: number[] };

export class YProtocolSession {
  readonly doc: Doc;
  readonly awareness: Awareness | null;
  reliable: boolean;

  private _send: YProtocolSessionOptions["send"];
  private _synced = false;
  private _delivery: ReliableSync;
  private _onDocUpdate: (update: Uint8Array, origin: unknown) => void;
  private _onAwarenessUpdate?: (change: AwarenessChange, origin: unknown) => void;

  constructor(doc: Doc, opts: YProtocolSessionOptions) {
    const {
      send,
      awareness = null,
      reliable = true,
      resendInterval,
      maxUnconfirmedResends,
      onFallback,
      setInterval: setIntervalFn,
      clearInterval: clearIntervalFn,
    } = opts ?? ({} as YProtocolSessionOptions);
    if (!doc) throw new TypeError("YProtocolSession requires a Y.Doc");
    if (typeof send !== "function") throw new TypeError("YProtocolSession requires a send(frame, id) function");

    this.doc = doc;
    this.awareness = awareness;
    this.reliable = reliable;
    this._send = send;

    this._delivery = new ReliableSync({
      merge: mergeUpdates,
      send: (update, id) => this._send(this._frameUpdate(update), id),
      resendInterval,
      maxUnconfirmedResends,
      onFallback,
      setInterval: setIntervalFn,
      clearInterval: clearIntervalFn,
    });

    this._onDocUpdate = (update: Uint8Array, origin: unknown) => {
      if (origin === this) return; // applied from the server; don't echo it back
      if (this.reliable && this._delivery.reliable) this._delivery.enqueue(update);
      else this._send(this._frameUpdate(update), undefined);
    };
    this.doc.on("update", this._onDocUpdate);

    if (this.awareness) {
      this._onAwarenessUpdate = ({ added, updated, removed }: AwarenessChange) => {
        const changed = added.concat(updated, removed);
        this._send(this._frameAwareness(changed), undefined, { awareness: true }); // fire-and-forget
      };
      this.awareness.on("update", this._onAwarenessUpdate);
    }
  }

  /** True once we've received the server's SyncStep2 (the document is caught up). */
  get synced(): boolean {
    return this._synced;
  }

  /** True while there are unacknowledged local document updates in flight. */
  get hasPending(): boolean {
    return this._delivery.hasPending;
  }

  /** Transport connected: send the opening handshake and replay the unacked tail. */
  onConnect(): void {
    this._send(this._frameSyncStep1(), undefined);
    if (this.awareness && this.awareness.getLocalState() !== null) {
      this._send(this._frameAwareness([this.doc.clientID]), undefined, { awareness: true });
    }
    if (this.reliable) this._delivery.onConnect();
  }

  /** Transport dropped: pause retransmits (queue kept) and clear remote presence. */
  onDisconnect(): void {
    this._synced = false;
    this._delivery.onDisconnect();
    if (this.awareness) {
      const remote = [...this.awareness.getStates().keys()].filter((c) => c !== this.doc.clientID);
      if (remote.length) removeAwarenessStates(this.awareness, remote, this);
    }
  }

  /** A reliable-delivery `{ ack: id }` envelope arrived. */
  ack(id: number): void {
    this._delivery.onAck(id);
  }

  /**
   * Decode and apply one incoming binary protocol frame (document sync, awareness,
   * query, or auth). Returns a reply frame to transmit (e.g. SyncStep2 answering a
   * SyncStep1, or an awareness reply to a query), or null if there's nothing to send.
   */
  receive(frame: Uint8Array): Uint8Array | null {
    const decoder = decoding.createDecoder(frame);
    const encoder = encoding.createEncoder();
    const type = decoding.readVarUint(decoder);
    switch (type) {
      case MessageType.Sync: {
        encoding.writeVarUint(encoder, MessageType.Sync);
        const syncType = readSyncMessage(decoder, encoder, this.doc, this);
        if (!this._synced && syncType === messageYjsSyncStep2) this._synced = true;
        break;
      }
      case MessageType.Awareness:
        if (this.awareness) applyAwarenessUpdate(this.awareness, decoding.readVarUint8Array(decoder), this);
        return null;
      case MessageType.QueryAwareness:
        if (!this.awareness) return null;
        encoding.writeVarUint(encoder, MessageType.Awareness);
        encoding.writeVarUint8Array(
          encoder,
          encodeAwarenessUpdate(this.awareness, [...this.awareness.getStates().keys()])
        );
        break;
      case MessageType.Auth:
        readAuthMessage(decoder, this.doc, (_doc, reason) => console.warn(`[yrb-lite] auth denied: ${reason}`));
        return null;
      default:
        return null;
    }
    return encoding.length(encoder) > 1 ? encoding.toUint8Array(encoder) : null;
  }

  /** Detach doc/awareness listeners and stop retransmits. */
  destroy(): void {
    this.doc.off("update", this._onDocUpdate);
    if (this.awareness && this._onAwarenessUpdate) this.awareness.off("update", this._onAwarenessUpdate);
    this._delivery.destroy();
  }

  private _frameSyncStep1(): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Sync);
    writeSyncStep1(e, this.doc);
    return encoding.toUint8Array(e);
  }

  private _frameUpdate(update: Uint8Array): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Sync);
    writeUpdate(e, update);
    return encoding.toUint8Array(e);
  }

  private _frameAwareness(clients: number[]): Uint8Array {
    const e = encoding.createEncoder();
    encoding.writeVarUint(e, MessageType.Awareness);
    encoding.writeVarUint8Array(e, encodeAwarenessUpdate(this.awareness as Awareness, clients));
    return encoding.toUint8Array(e);
  }
}
