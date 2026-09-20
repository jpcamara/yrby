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
// call `connect()`. Watch the connection with `onStatusChange(({ status, pending }) => ...)`
// or the `status` and `hasPending` getters. Editors that must not bind before the first sync
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

/** Payload passed to onStatusChange listeners. Fires when either field changes. */
export interface StatusEvent {
  status: ProviderStatus;
  /** True while local edits await the server's acknowledgment. */
  pending: boolean;
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
  #connected = false; // transport up, per the cable's own callbacks
  #generation = 0; // bumped whenever a subscription is retired, so its late callbacks go quiet
  #destroyed = false;
  // The last event listeners saw. A refresh notifies only when something differs.
  #last: StatusEvent = { status: "disconnected", pending: false };
  #statusListeners = new Set<(event: StatusEvent) => void>();
  #resolveSynced!: () => void;
  #onDocUpdate = (): void => this.#refreshStatus(); // a local edit may have made the queue non-empty
  #page: { hide: () => void; show: (event: PageTransitionEvent) => void } | null = null;

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
   * It settles on the first catch-up and stays settled across later
   * reconnects, even while `synced` is false during a re-handshake; use
   * `onStatusChange` to track the live connection. If the provider is
   * destroyed before the first sync, it never settles.
   */
  readonly whenSynced = new Promise<void>((resolve) => { this.#resolveSynced = resolve; });

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
    // After the session's own listener, so the queue already holds the edit.
    this.doc.on("update", this.#onDocUpdate);
  }

  /** True once the document has caught up with the server (received a SyncStep2). */
  get synced(): boolean {
    return this.session.synced;
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
    return this.#last.status;
  }

  /** Subscribe to status changes. Returns an unsubscribe function. */
  onStatusChange(listener: (event: StatusEvent) => void): () => void {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }

  connect(): void {
    if (this.#destroyed) throw new Error("provider is destroyed");
    if (this.#subscription) return;
    const provider = this;
    const generation = ++this.#generation;
    let creating = true;
    const current = () => generation === provider.#generation && !provider.#destroyed;
    // A consumer may call back inside create(). Wait until the returned
    // subscription is installed so the opening handshake has somewhere to send.
    const run = (callback: () => void) => {
      if (creating) queueMicrotask(() => { if (current()) callback(); });
      else if (current()) callback();
    };
    this.#subscription = this.consumer.subscriptions.create(
      { channel: this.channelName, ...this.channelParams },
      {
        received(message: CableMessage) { run(() => {
          // Reliable-delivery ack: confirm + prune the local queue.
          if (message && message.ack !== undefined) {
            provider.session.acknowledge(message.ack);
            provider.#refreshStatus(); // the queue may have just emptied
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
        }); },
        connected() { run(() => {
          provider.#connected = true;
          provider.session.resume(); // handshake + replay the unacked tail
          provider.#refreshStatus();
        }); },
        disconnected() { run(() => {
          provider.#connected = false;
          provider.session.pause(); // keep the queue; forget peers' cursors (ours stays; nothing can be sent now)
          provider.#refreshStatus(); // subscription still set -> "connecting" (retrying)
        }); },
        rejected() { run(() => {
          // The channel refused the subscription (auth, missing doc). Tear down
          // first, then report: the handler may build a replacement, and it
          // must not be the one we tear down. Left alone, the provider would
          // sit at "connecting" forever, silently queueing edits.
          provider.disconnect();
          provider.#onError(new Error("subscription rejected by the server"), "rejected");
        }); },
      }
    );
    creating = false;
    this.#watchPage();
    this.#refreshStatus(); // -> "connecting"
  }

  disconnect(): void {
    if (!this.#subscription) return;
    const sub = this.#subscription;
    // Silence the old subscription now, not when a replacement arrives: its
    // unsubscribe is deferred below, so a frame still on the wire, or a late
    // rejected/connected, must not reach the session or a replacement.
    ++this.#generation;
    // Tell peers we're gone while the transport is still live, then pause and
    // detach. Defer the unsubscribe one microtask so the removal frame flushes
    // before the channel tears down.
    this.session.removeLocalAwareness();
    this.session.pause();
    this.#connected = false;
    this.#subscription = null;
    this.#unwatchPage();
    // Universal teardown: both @rails/actioncable and @anycable/web subscriptions
    // expose unsubscribe() (Rails' just calls consumer.subscriptions.remove(this)
    // internally). @anycable has NO consumer.subscriptions.remove, so calling that
    // would throw there.
    queueMicrotask(() => sub.unsubscribe?.());
    this.#refreshStatus(); // -> "disconnected"
  }

  /**
   * Resubscribe with updated channel params, such as a renewed grant. The
   * doc, the delivery queue, awareness, and this provider's ack route all
   * carry over; only the cable subscription is replaced. A no-op after
   * destroy().
   */
  renew(params: object): void {
    if (this.#destroyed) return;
    Object.assign(this.channelParams, params);
    this.disconnect();
    this.connect();
  }

  destroy(): void {
    if (this.#destroyed) return;
    this.disconnect();
    this.#destroyed = true;
    this.session.destroy();
    this.awareness.destroy(); // stops its reaper timer
    this.doc.off("update", this.#onDocUpdate);
    this.#statusListeners.clear();
  }

  #computeStatus(): ProviderStatus {
    if (!this.#subscription) return "disconnected";
    if (!this.#connected) return "connecting";
    return this.session.synced ? "synced" : "connected";
  }

  #refreshStatus(): void {
    const status = this.#computeStatus();
    const pending = this.hasPending;
    if (status === this.#last.status && pending === this.#last.pending) return;
    this.#last = { status, pending };
    if (status === "synced") this.#resolveSynced();
    // A listener that throws is an application bug, not a transport failure:
    // report it and keep going, so one bad listener cannot stop the others or
    // break the cable callback that triggered the refresh.
    for (const listener of this.#statusListeners) {
      try {
        listener({ status, pending });
      } catch (error) {
        this.#onError(error, "listener");
      }
    }
  }

  // Presence around the page lifecycle. `pagehide` removes our cursor while
  // the socket is still live, so peers drop it now rather than after the
  // awareness timeout. A `pageshow` with `persisted` is a bfcache return, so
  // the cursor goes back; editor bindings set awareness once at setup, and
  // without this the returning user would be a ghost.
  #watchPage(): void {
    if (typeof window === "undefined" || this.#page) return;
    let stashed: Record<string, unknown> | null = null;
    this.#page = {
      hide: () => {
        stashed = this.awareness.getLocalState();
        this.session.removeLocalAwareness();
      },
      show: (event) => {
        if (!event.persisted || !stashed) return;
        if (this.awareness.getLocalState() === null) this.awareness.setLocalState(stashed);
        stashed = null;
      },
    };
    window.addEventListener("pagehide", this.#page.hide);
    window.addEventListener("pageshow", this.#page.show);
  }

  #unwatchPage(): void {
    if (!this.#page || typeof window === "undefined") return;
    window.removeEventListener("pagehide", this.#page.hide);
    window.removeEventListener("pageshow", this.#page.show);
    this.#page = null;
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
