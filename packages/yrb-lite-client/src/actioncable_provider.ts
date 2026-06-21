// A ready-made Yjs provider for the yrb-lite y-websocket protocol over
// ActionCable / AnyCable. It owns the cable subscription and translates between
// the cable's JSON envelope (`{ update, id }` / `{ ack }`, base64) and raw
// protocol frames; everything else (sync steps, encode/decode, awareness,
// reliable delivery) lives in YProtocolSession. So this is just the transport glue.
//
// Awareness/presence frames are sent via AnyCable's `whisper` when the
// subscription supports it (client-to-client, no server round-trip); on plain
// ActionCable (no `whisper`) they fall back to a normal `send` and the server
// relays them. Document updates always go through `send` (they must be
// recorded/acked).
//
// The constructor does NOT auto-connect: wire your editor binding first, then
// call `connect()`. Same `(doc, consumer, channelName, channelParams, opts)`
// shape as a typical y-rb/actioncable provider.
//
// Observe the connection with `provider.on("status", ({ status }) => ...)`
// (`"connecting" | "connected" | "synced" | "disconnected"`) or the `status`
// getter. On `disconnect()` / `destroy()` -- and on browser `pagehide` -- the
// provider broadcasts a presence removal so peers drop our cursor immediately
// instead of waiting for the awareness timeout.
import { YProtocolSession, MessageType, type YProtocolSessionOptions, type SendOptions } from "./y_protocol_session.js";
import { toBase64, fromBase64 } from "./base64.js";
import { Awareness } from "y-protocols/awareness";
import type { Doc } from "yjs";

/**
 * Connection lifecycle, folded into one signal (no separate "sync" event):
 *   connecting   -- subscription created, transport not up yet
 *   connected    -- transport up, exchanging sync steps (UI: "syncing")
 *   synced       -- caught up with the server
 *   disconnected -- torn down via disconnect()/destroy() (a dropped transport
 *                   that ActionCable will retry shows as "connecting")
 */
export type ProviderStatus = "connecting" | "connected" | "synced" | "disconnected";

/** Payload for the `"status"` event. */
export interface StatusEvent {
  status: ProviderStatus;
}

/** The minimal slice of an ActionCable/AnyCable subscription this provider uses. */
export interface CableSubscription {
  send(data: unknown): unknown;
  /** AnyCable client-to-client broadcast; absent on plain ActionCable. */
  whisper?(data: unknown): unknown;
  unsubscribe?(): void;
}

/** The minimal slice of an ActionCable/AnyCable consumer this provider uses. */
export interface CableConsumer {
  subscriptions: {
    create(params: object, mixin: object): CableSubscription;
    remove(subscription: CableSubscription): void;
  };
}

export interface ActionCableProviderOptions
  extends Pick<
    YProtocolSessionOptions,
    "reliable" | "resendInterval" | "maxUnconfirmedResends" | "onFallback" | "onError"
  > {
  /**
   * Awareness/presence instance. Omit (`undefined`) for a fresh
   * `new Awareness(doc)` the provider owns; pass `null` to disable awareness
   * entirely; pass your own to share one you manage.
   */
  awareness?: Awareness | null;
}

interface CableMessage {
  m?: string;
  update?: string;
  ack?: number;
}

export class ActionCableProvider {
  readonly doc: Doc;
  readonly consumer: CableConsumer;
  readonly channelName: string;
  readonly channelParams: object;
  readonly awareness: Awareness | null;
  readonly session: YProtocolSession;
  private subscription: CableSubscription | null = null;
  private _onError: (error: unknown, context: string) => void;
  private _ownsAwareness: boolean;
  private _connected = false;
  private _status: ProviderStatus = "disconnected";
  private _statusListeners = new Set<(event: StatusEvent) => void>();
  private _onUnload: (() => void) | null = null;

  constructor(
    doc: Doc,
    consumer: CableConsumer,
    channelName: string,
    channelParams: object = {},
    opts: ActionCableProviderOptions = {}
  ) {
    this.doc = doc;
    this.consumer = consumer;
    this.channelName = channelName;
    this.channelParams = channelParams;
    // undefined -> create one we own; null -> awareness disabled; value -> borrowed.
    this._ownsAwareness = opts.awareness === undefined;
    this.awareness = opts.awareness === undefined ? new Awareness(doc) : opts.awareness;
    this._onError = opts.onError ?? ((error, context) => console.warn(`[yrb-lite] ${context}:`, error));

    this.session = new YProtocolSession(doc, {
      awareness: this.awareness,
      reliable: opts.reliable,
      resendInterval: opts.resendInterval,
      maxUnconfirmedResends: opts.maxUnconfirmedResends,
      onFallback: opts.onFallback,
      onError: this._onError,
      send: (frame, id, sendOpts) => this._send(frame, id, sendOpts),
    });
  }

  /** True once the document has caught up with the server (received a SyncStep2). */
  get synced(): boolean {
    return this.session.synced;
  }

  /** True while there are unacknowledged local document updates in flight. */
  get hasPending(): boolean {
    return this.session.hasPending;
  }

  /** Current connection status. See {@link ProviderStatus}. */
  get status(): ProviderStatus {
    return this._status;
  }

  /** Subscribe to status changes. Returns an unsubscribe function. */
  on(event: "status", listener: (event: StatusEvent) => void): () => void {
    if (event !== "status") return () => {};
    this._statusListeners.add(listener);
    return () => this._statusListeners.delete(listener);
  }

  /** Remove a previously-registered status listener. */
  off(event: "status", listener: (event: StatusEvent) => void): void {
    if (event === "status") this._statusListeners.delete(listener);
  }

  connect(): void {
    if (this.subscription) return;
    const provider = this;
    this.subscription = this.consumer.subscriptions.create(
      { channel: this.channelName, ...this.channelParams },
      {
        received(message: CableMessage) {
          // Reliable-delivery ack: confirm + prune the local queue.
          if (message && message.ack !== undefined) {
            provider.session.ack(message.ack);
            return;
          }
          const payload = message && (message.m ?? message.update);
          if (typeof payload !== "string") return;
          // Guard base64 decode too: a malformed envelope must not throw into
          // the cable callback (session.receive is itself defensive).
          let frame: Uint8Array;
          try {
            frame = fromBase64(payload);
          } catch (error) {
            provider._onError(error, "received");
            return;
          }
          const reply = provider.session.receive(frame);
          if (reply) provider._send(reply, undefined); // e.g. SyncStep2 answering a SyncStep1
          provider._refreshStatus(); // a SyncStep2 may have just flipped us to "synced"
        },
        connected() {
          provider._connected = true;
          provider.session.onConnect(); // handshake + replay the unacked tail
          provider._refreshStatus();
        },
        disconnected() {
          provider._connected = false;
          provider.session.onDisconnect(); // pause retransmits, clear remote presence
          provider._refreshStatus(); // subscription still set -> "connecting" (retrying)
        },
      }
    );
    this._installUnloadHandler();
    this._refreshStatus(); // -> "connecting"
  }

  disconnect(): void {
    if (!this.subscription) return;
    const sub = this.subscription;
    // Tell peers we're gone while the transport is still live, then pause and
    // detach. Defer the unsubscribe one microtask so the removal frame flushes
    // before the channel tears down.
    this.session.removeLocalAwareness();
    this.session.onDisconnect();
    this._connected = false;
    this.subscription = null;
    this._removeUnloadHandler();
    queueMicrotask(() => this.consumer.subscriptions.remove(sub));
    this._refreshStatus(); // -> "disconnected"
  }

  destroy(): void {
    this.disconnect();
    this.session.destroy();
    // Only tear down the Awareness if we created it; a caller-supplied one is
    // theirs to own (and destroying it stops its reaper timer either way).
    if (this._ownsAwareness && this.awareness) this.awareness.destroy();
    this._statusListeners.clear();
  }

  private _computeStatus(): ProviderStatus {
    if (!this.subscription) return "disconnected";
    if (!this._connected) return "connecting";
    return this.session.synced ? "synced" : "connected";
  }

  private _refreshStatus(): void {
    const next = this._computeStatus();
    if (next === this._status) return;
    this._status = next;
    for (const listener of this._statusListeners) listener({ status: next });
  }

  // Best-effort presence removal when the tab/page goes away (close, navigation,
  // bfcache). `pagehide` fires while the socket is still live and is bfcache-safe
  // (unlike `beforeunload`, which can block it). Sends are not guaranteed to
  // flush on unload, so the server-side awareness timeout remains the backstop.
  private _installUnloadHandler(): void {
    if (typeof window === "undefined" || this._onUnload) return;
    this._onUnload = () => this.session.removeLocalAwareness();
    window.addEventListener("pagehide", this._onUnload);
  }

  private _removeUnloadHandler(): void {
    if (typeof window === "undefined" || !this._onUnload) return;
    window.removeEventListener("pagehide", this._onUnload);
    this._onUnload = null;
  }

  // Send one raw protocol frame over the cable. Awareness frames are whispered
  // when the subscription supports it (AnyCable), else sent normally; document
  // frames always go through `send`. `id` (reliable doc updates) is tagged onto
  // the envelope so the server can ack. A no-op while disconnected: reliable
  // frames stay queued in the session and flush on the next connect().
  private _send(frame: Uint8Array, id: number | undefined, opts?: SendOptions): void {
    const sub = this.subscription;
    if (!sub) return;
    const update = toBase64(frame);
    const payload = id === undefined ? { update } : { update, id };
    const isAwareness = opts?.awareness ?? frame[0] === MessageType.Awareness;
    // Awareness rides AnyCable's whisper automatically when the subscription
    // supports it (client-to-client, no server round-trip); otherwise a normal
    // send the server relays. Document updates always send (recorded/acked).
    if (isAwareness && typeof sub.whisper === "function") sub.whisper(payload);
    else sub.send(payload);
  }
}
