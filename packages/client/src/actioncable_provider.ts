// Yjs provider for the yrby y-websocket protocol over ActionCable / AnyCable.
// It owns the cable subscription and translates between the cable's JSON envelope
// (`{ update, id }` / `{ ack }`, base64) and raw protocol frames. Everything else
// (sync steps, encode/decode, awareness, reliable delivery) lives in
// YProtocolSession; this is the transport glue.
//
// Awareness frames use AnyCable's `whisper` when available, under a separate
// awareness-only envelope. Document frames always use `send` so they go through
// the server's persistence/ack path.
//
// The constructor does not auto-connect: wire up your editor binding first, then
// call `connect()`. Watch the connection with `onStatusChange(({ status }) => ...)`
// or the `status` getter. Editors that must not bind before the first sync
// can `await provider.whenSynced` after connect(). On `disconnect()`/`destroy()`,
// and on browser `pagehide`, the provider broadcasts a presence removal so peers
// drop our cursor right away instead of waiting for the awareness timeout.
import { YProtocolSession, MessageType, type YProtocolSessionOptions } from "./y_protocol_session.js";
import { toBase64, fromBase64 } from "./base64.js";
import { Awareness } from "y-protocols/awareness";
import type { Doc } from "yjs";

/**
 * Connection lifecycle, folded into one signal (no separate "sync" event):
 * connecting (subscription created, transport not up yet), connected (transport
 * up, exchanging sync steps; UI: "syncing"), synced (caught up), and disconnected
 * (torn down via disconnect()/destroy()). A dropped transport that ActionCable
 * will retry shows as "connecting", not "disconnected".
 */
export type ProviderStatus = "connecting" | "connected" | "synced" | "disconnected";

/** Payload passed to onStatusChange listeners. */
export interface StatusEvent {
  status: ProviderStatus;
}

/** The minimal slice of an ActionCable/AnyCable subscription this provider uses. */
export interface CableSubscription {
  send(data: unknown): unknown;
  /** AnyCable client-to-client broadcast; absent on plain ActionCable. */
  whisper?(data: unknown): unknown;
  /** Teardown. Present on both @rails/actioncable and @anycable/web. */
  unsubscribe?(): void;
}

/**
 * The minimal slice of an ActionCable/AnyCable consumer this provider uses.
 *
 * Deliberately loose so the consumers from both `@rails/actioncable` and
 * `@anycable/web` are directly assignable -- no adapter or casts. `create` is
 * widened to the channel/params shapes both libs accept, with an optional mixin
 * (the handlers object). There's no `subscriptions.remove`: the provider tears
 * down via `subscription.unsubscribe()` (universal), and @anycable has no such
 * method anyway.
 */
export interface CableConsumer {
  subscriptions: {
    create(channel: string | object, mixin?: object): CableSubscription;
  };
}

export type ActionCableProviderOptions = Pick<YProtocolSessionOptions, "resendInterval" | "onError">;

interface CableMessage {
  update?: string;
  awareness?: string;
  ack?: number;
}

export class ActionCableProvider {
  readonly doc: Doc;
  readonly consumer: CableConsumer;
  readonly channelName: string;
  readonly channelParams: object;
  readonly awareness: Awareness;
  readonly session: YProtocolSession;
  #subscription: CableSubscription | null = null;
  #onError: (error: unknown, context: string) => void;
  #connected = false;
  #status: ProviderStatus = "disconnected";
  #statusListeners = new Set<(event: StatusEvent) => void>();
  #whenSynced: Promise<void> | null = null;
  // `session.synced` resets on every transport drop (a reconnect
  // re-handshakes). Whether the first catch-up has ever happened is tracked
  // separately here, so `whenSynced` does not depend on when it is first
  // read.
  #everSynced = false;
  #onUnload: (() => void) | null = null;
  #onRestore: ((event: PageTransitionEvent) => void) | null = null;
  #stashedPresence: Record<string, unknown> | null = null;

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
    this.awareness = new Awareness(doc);
    this.#onError = opts.onError ?? ((error, context) => console.warn(`[yrby] ${context}:`, error));

    this.session = new YProtocolSession(doc, {
      awareness: this.awareness,
      resendInterval: opts.resendInterval,
      onError: this.#onError,
      send: (frame, id) => this.#send(frame, id),
    });
  }

  /** True once the document has caught up with the server (received a SyncStep2). */
  get synced(): boolean {
    return this.session.synced;
  }

  /**
   * Resolves once the document has first caught up with the server. Most
   * editor bindings seed an empty document when they mount, so binding
   * before the server's state arrives makes each client insert its own
   * top-level node. Create the editor after this resolves:
   *
   *   provider.connect();
   *   await provider.whenSynced;
   *   // now hand the doc to the editor binding
   *
   * Resolves immediately if the first catch-up has already happened, even
   * while the transport is down (`synced` is false during a reconnect;
   * whether the doc has ever synced does not change). It stays resolved
   * across later reconnects; use `onStatusChange` to track the live
   * connection. If the provider is destroyed before the first sync, the
   * promise never settles.
   */
  get whenSynced(): Promise<void> {
    this.#whenSynced ??= this.#everSynced
      ? Promise.resolve()
      : new Promise((resolve) => {
          const off = this.onStatusChange(({ status }) => {
            if (status !== "synced") return;
            off();
            resolve();
          });
        });
    return this.#whenSynced;
  }

  /** True while there are unacknowledged local document updates in flight. */
  get hasPending(): boolean {
    return this.session.hasPending;
  }

  /**
   * Apply a bootstrap/restore update (initial HTTP state, a server snapshot, an
   * import) without re-sending it to the server as a local edit. Call it once per
   * chunk of already-durable state when seeding the doc, before `connect()`:
   *
   *   provider.applyRemoteUpdate(fromBase64(initialState));
   *   priorUpdates.forEach((u) => provider.applyRemoteUpdate(fromBase64(u)));
   *   provider.connect();
   *
   * See {@link YProtocolSession.applyRemoteUpdate} for why a bare `Y.applyUpdate`
   * would be re-broadcast as a pending change instead.
   */
  applyRemoteUpdate(update: Uint8Array): void {
    this.session.applyRemoteUpdate(update);
  }

  /** Current connection status. See {@link ProviderStatus}. */
  get status(): ProviderStatus {
    return this.#status;
  }

  /** Subscribe to status changes. Returns an unsubscribe function. */
  onStatusChange(listener: (event: StatusEvent) => void): () => void {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }

  connect(): void {
    if (this.#subscription) return;
    const provider = this;
    this.#subscription = this.consumer.subscriptions.create(
      { channel: this.channelName, ...this.channelParams },
      {
        received(message: CableMessage) {
          // Reliable-delivery ack: confirm + prune the local queue.
          if (message && message.ack !== undefined) {
            provider.session.ack(message.ack);
            return;
          }
          const awarenessPayload = message && message.awareness;
          const payload = message && (awarenessPayload ?? message.update);
          if (typeof payload !== "string") return;
          // Guard base64 decode too: a malformed envelope must not throw into
          // the cable callback (session.receive is itself defensive).
          let frame: Uint8Array;
          try {
            frame = fromBase64(payload);
          } catch (error) {
            provider.#onError(error, "received");
            return;
          }
          if (awarenessPayload !== undefined && frame[0] !== MessageType.Awareness) {
            provider.#onError(new Error("awareness envelope carried a non-awareness frame"), "received");
            return;
          }
          const reply = provider.session.receive(frame);
          if (reply) provider.#send(reply, undefined); // e.g. SyncStep2 answering a SyncStep1
          provider.#refreshStatus(); // a SyncStep2 may have just flipped us to "synced"
        },
        connected() {
          provider.#connected = true;
          provider.session.onConnect(); // handshake + replay the unacked tail
          provider.#refreshStatus();
        },
        disconnected() {
          provider.#connected = false;
          provider.session.onDisconnect(); // pause retransmits, clear remote presence
          provider.#refreshStatus(); // subscription still set -> "connecting" (retrying)
        },
        rejected() {
          // The channel refused the subscription (auth, missing doc). Surface
          // it and tear down — otherwise the provider sits at "connecting"
          // forever, silently queueing edits. The app decides what's next.
          provider.#onError(new Error("subscription rejected by the server"), "rejected");
          provider.disconnect();
        },
      }
    );
    this.#installUnloadHandler();
    this.#refreshStatus(); // -> "connecting"
  }

  disconnect(): void {
    if (!this.#subscription) return;
    const sub = this.#subscription;
    // Tell peers we're gone while the transport is still live, then pause and
    // detach. Defer the unsubscribe one microtask so the removal frame flushes
    // before the channel tears down.
    this.session.removeLocalAwareness();
    this.session.onDisconnect();
    this.#connected = false;
    this.#subscription = null;
    this.#removeUnloadHandler();
    // Universal teardown: both @rails/actioncable and @anycable/web subscriptions
    // expose unsubscribe() (Rails' just calls consumer.subscriptions.remove(this)
    // internally). @anycable has NO consumer.subscriptions.remove, so calling that
    // would throw there.
    queueMicrotask(() => sub.unsubscribe?.());
    this.#refreshStatus(); // -> "disconnected"
  }

  destroy(): void {
    this.disconnect();
    this.session.destroy();
    this.awareness.destroy(); // stops its reaper timer
    this.#statusListeners.clear();
  }

  #computeStatus(): ProviderStatus {
    if (!this.#subscription) return "disconnected";
    if (!this.#connected) return "connecting";
    return this.session.synced ? "synced" : "connected";
  }

  #refreshStatus(): void {
    const next = this.#computeStatus();
    if (next === this.#status) return;
    this.#status = next;
    if (next === "synced") this.#everSynced = true;
    for (const listener of this.#statusListeners) listener({ status: next });
  }

  // Presence teardown/restore around page lifecycle:
  // - `pagehide`: remove local presence while the socket is still live so peers
  //   drop our cursor now (bfcache-safe; the awareness timeout is the backstop).
  // - `pageshow` with `persisted`: the user came BACK (bfcache restore), so put
  //   their presence back — editors set awareness once at setup, so without
  //   this they'd rejoin as a ghost with no cursor.
  #installUnloadHandler(): void {
    if (typeof window === "undefined" || this.#onUnload) return;
    this.#onUnload = () => {
      this.#stashedPresence = this.awareness.getLocalState();
      this.session.removeLocalAwareness();
    };
    this.#onRestore = (event: PageTransitionEvent) => {
      if (!event.persisted || !this.#stashedPresence) return;
      if (this.awareness.getLocalState() === null) {
        this.awareness.setLocalState(this.#stashedPresence);
      }
      this.#stashedPresence = null;
    };
    window.addEventListener("pagehide", this.#onUnload);
    window.addEventListener("pageshow", this.#onRestore);
  }

  #removeUnloadHandler(): void {
    if (typeof window === "undefined") return;
    if (this.#onUnload) {
      window.removeEventListener("pagehide", this.#onUnload);
      this.#onUnload = null;
    }
    if (this.#onRestore) {
      window.removeEventListener("pageshow", this.#onRestore);
      this.#onRestore = null;
    }
  }

  // Send one raw protocol frame over the cable. Awareness frames are whispered
  // when AnyCable exposes `subscription.whisper`; otherwise they fall back to a
  // normal send. `id` (reliable doc updates) is tagged onto the envelope so the
  // server can ack. A no-op while disconnected: reliable frames stay queued in
  // the session and flush on the next connect().
  #send(frame: Uint8Array, id: number | undefined): void {
    const sub = this.#subscription;
    if (!sub) return;
    const update = toBase64(frame);
    const isAwareness = frame[0] === MessageType.Awareness;
    // Route transport failures (sync throws, or @anycable/web's rejected
    // promises) to onError instead of letting them escape into update
    // handlers. A failed send is recoverable: reliable frames stay queued
    // until acked, and awareness is best-effort anyway.
    try {
      if (isAwareness && typeof sub.whisper === "function") {
        this.#observe(sub.whisper({ awareness: update }));
        return;
      }
      const payload = id === undefined ? { update } : { update, id };
      this.#observe(sub.send(payload));
    } catch (error) {
      this.#onError(error, "send");
    }
  }

  // Attach a rejection handler when a transport returns a promise, so failures
  // surface via onError instead of as unhandled rejections.
  #observe(result: unknown): void {
    if (result instanceof Promise) {
      result.catch((error) => this.#onError(error, "send"));
    }
  }
}
