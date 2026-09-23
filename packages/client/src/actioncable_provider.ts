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

type Opening = { phase: "subscribing" };
type Connection = { opening: Opening; subscription: CableSubscription };
type StopReason = "disconnect" | "reject" | "destroy";
type ProviderState =
  | { phase: "disconnected" | "destroyed" }
  | Opening
  | { phase: "connecting" | "connected"; connection: Connection }
  | { phase: "stopping"; connection: Connection; reason: StopReason };

export class ActionCableProvider {
  readonly doc: Doc;
  readonly consumer: CableConsumer;
  readonly channelName: string;
  readonly channelParams: object;
  readonly awareness: Awareness;
  readonly session: YProtocolSession;
  #state: ProviderState = { phase: "disconnected" };
  #onError: (error: unknown, context: string) => void;
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
    const onError = opts.onError ?? ((error, context) => console.warn(`[yrby] ${context}:`, error));
    this.#onError = (error, context) => {
      try { onError(error, context); }
      catch (callbackError) { console.warn("[yrby] onError callback failed:", callbackError, "while reporting:", error); }
    };
    this.awareness = new ProviderAwareness(doc, this.#onError);

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
    return this.#computeStatus();
  }

  /** Subscribe to status changes. Returns an unsubscribe function. */
  onStatusChange(listener: (event: StatusEvent) => void): () => void {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }

  connect(): void {
    const current = this.#state;
    if (current.phase === "destroyed" || (current.phase === "stopping" && current.reason === "destroy")) {
      throw new Error("provider is destroyed");
    }
    if (current.phase !== "disconnected") return;
    const opening: Opening = { phase: "subscribing" };
    this.#state = opening;
    const run = (callback: (connection: Connection) => void) => {
      const invoke = () => {
        const state = this.#state;
        if ((state.phase === "connecting" || state.phase === "connected") && state.connection.opening === opening) {
          callback(state.connection);
        }
      };
      // Synchronous create callbacks wait for the subscription to be installed.
      if (this.#state === opening) queueMicrotask(invoke);
      else invoke();
    };
    let subscription: CableSubscription;
    try {
      subscription = this.consumer.subscriptions.create(
        { channel: this.channelName, ...this.channelParams },
        {
          received: (message: CableMessage) => run(connection => this.#receive(message, connection)),
          connected: () => run(connection => this.#connected(connection)),
          disconnected: () => run(connection => this.#lost(connection)),
          rejected: () => run(connection => this.#stop("reject", connection)),
        }
      );
    } catch (error) {
      if (this.#state === opening) {
        this.#state = { phase: "disconnected" };
        this.#refreshStatus();
        throw error;
      }
      return;
    }
    if (this.#state !== opening) { this.#unsubscribe(subscription); return; }
    this.#state = { phase: "connecting", connection: { opening, subscription } };
    this.#watchPage();
    this.#refreshStatus();
  }

  disconnect(): void { this.#stop("disconnect"); }

  /**
   * Resubscribe with updated channel params, such as a renewed grant. The
   * doc, the delivery queue, awareness, and this provider's ack route all
   * carry over; only the cable subscription is replaced. A no-op after
   * destroy().
   */
  renew(params: object): void {
    if (this.#state.phase === "destroyed" || (this.#state.phase === "stopping" && this.#state.reason === "destroy")) return;
    Object.assign(this.channelParams, params);
    this.disconnect();
    this.connect();
  }

  destroy(): void { this.#stop("destroy"); }

  #active(connection: Connection): boolean {
    const current = this.#state;
    return (current.phase === "connecting" || current.phase === "connected") && current.connection === connection;
  }
  #connected(connection: Connection): void {
    if (!this.#active(connection) || this.#state.phase === "connected") return;
    this.#state = { phase: "connected", connection };
    this.session.resume();
    this.#refreshStatus();
  }
  #lost(connection: Connection): void {
    if (!this.#active(connection)) return;
    this.#state = { phase: "connecting", connection };
    this.session.pause();
    this.#refreshStatus();
  }
  #stop(reason: StopReason, connection?: Connection): void {
    const current = this.#state;
    if (current.phase === "destroyed" || (connection && !this.#active(connection))) return;
    if (current.phase === "stopping") {
      // Destruction supersedes a disconnect triggered during presence removal.
      if (reason === "destroy" && current.reason !== "destroy") this.#state = { ...current, reason };
      return;
    }
    if ("connection" in current) {
      this.#state = { phase: "stopping", connection: current.connection, reason };
      this.#unwatchPage();
      // Retired callbacks are silent, but the old subscription can still
      // send presence removal before its deferred unsubscribe.
      this.session.removeLocalAwareness();
      this.session.pause();
      this.#unsubscribe(current.connection.subscription);
      this.#finishStop(current.connection);
      return;
    }
    if (reason === "disconnect" && current.phase === "disconnected") return;
    this.#state = { phase: reason === "destroy" ? "destroyed" : "disconnected" };
    if (reason === "destroy") this.#destroyOwned();
    this.#refreshStatus();
    if (reason === "destroy") this.#statusListeners.clear();
  }
  #finishStop(connection: Connection): void {
    const current = this.#state;
    if (current.phase !== "stopping" || current.connection !== connection) return;
    const destroyed = current.reason === "destroy";
    this.#state = { phase: destroyed ? "destroyed" : "disconnected" };
    if (destroyed) this.#destroyOwned();
    else if (current.reason === "reject") this.#onError(new Error("subscription rejected by the server"), "rejected");
    this.#refreshStatus();
    if (destroyed) this.#statusListeners.clear();
  }
  #destroyOwned(): void {
    this.session.destroy();
    this.awareness.destroy();
    this.doc.off("update", this.#onDocUpdate);
  }

  #unsubscribe(subscription: CableSubscription): void {
    queueMicrotask(() => {
      try { subscription.unsubscribe?.(); }
      catch (error) { this.#onError(error, "unsubscribe"); }
    });
  }

  #receive(message: CableMessage, connection: Connection): void {
    if (message && message.ack !== undefined) {
      this.session.acknowledge(message.ack);
      this.#refreshStatus();
      return;
    }
    const awarenessPayload = message && message.awareness;
    const payload = message && (awarenessPayload ?? message.update);
    if (typeof payload !== "string") return;
    let frame: Uint8Array;
    try {
      frame = fromBase64(payload);
    } catch (error) {
      this.#onError(error, "received");
      return;
    }
    if (awarenessPayload !== undefined && frame[0] !== MessageType.Awareness) {
      this.#onError(new Error("awareness envelope carried a non-awareness frame"), "received");
      return;
    }
    const reply = this.session.receive(frame);
    const state = this.#state;
    if (reply && (state.phase === "connecting" || state.phase === "connected") && state.connection === connection) {
      this.#send(reply, undefined);
    }
    this.#refreshStatus();
  }

  #computeStatus(): ProviderStatus {
    switch (this.#state.phase) {
      case "subscribing":
      case "connecting": return "connecting";
      case "connected": return this.session.synced ? "synced" : "connected";
      default: return "disconnected";
    }
  }

  #refreshStatus(): void {
    const status = this.#computeStatus();
    const pending = this.hasPending;
    if (status === this.#last.status && pending === this.#last.pending) return;
    const event = this.#last = { status, pending };
    if (status === "synced") this.#resolveSynced();
    // A listener that throws is an application bug, not a transport failure:
    // report it and keep going, so one bad listener cannot stop the others or
    // break the cable callback that triggered the refresh.
    for (const listener of this.#statusListeners) {
      if (this.#last !== event) break; // a listener caused a newer transition
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
    const page = this.#page = {
      hide: (): void => {
        if (this.#page !== page) return;
        stashed = this.awareness.getLocalState();
        this.session.removeLocalAwareness();
      },
      show: (event: PageTransitionEvent): void => {
        if (this.#page !== page || !event.persisted || !stashed) return;
        if (this.awareness.getLocalState() === null) this.awareness.setLocalState(stashed);
        stashed = null;
      },
    };
    window.addEventListener("pagehide", this.#page.hide);
    window.addEventListener("pageshow", this.#page.show);
  }

  #unwatchPage(): void {
    if (!this.#page || typeof window === "undefined") return;
    const page = this.#page;
    this.#page = null;
    window.removeEventListener("pagehide", page.hide);
    window.removeEventListener("pageshow", page.show);
  }

  // Send one raw protocol frame over the cable. Awareness frames are whispered
  // when AnyCable exposes `subscription.whisper`; otherwise they fall back to a
  // normal send. `id` (reliable doc updates) is tagged onto the envelope so the
  // server can ack. A no-op while disconnected: reliable frames stay queued in
  // the session and flush on the next connect().
  #send(frame: Uint8Array, id: number | undefined): void {
    const state = this.#state;
    if (!("connection" in state)) return;
    if (state.phase === "stopping" && frame[0] !== MessageType.Awareness) return;
    const sub = state.connection.subscription;
    const update = toBase64(frame);
    const isAwareness = frame[0] === MessageType.Awareness;
    // Route transport failures (sync throws, or @anycable/web's rejected
    // promises) to onError instead of letting them escape into update
    // handlers. A failed send is recoverable: reliable frames stay queued
    // until acked, and awareness is best-effort anyway.
    try {
      if (isAwareness && typeof sub.whisper === "function") {
        this.#observe(sub.whisper({ awareness: update }), state.connection);
        return;
      }
      const payload = id === undefined ? { update } : { update, id };
      this.#observe(sub.send(payload), state.connection);
    } catch (error) {
      if ("connection" in this.#state && this.#state.connection === state.connection) this.#onError(error, "send");
    }
  }

  // Attach a rejection handler when a transport returns a promise, so failures
  // surface via onError instead of as unhandled rejections.
  #observe(result: unknown, connection: Connection): void {
    if (result instanceof Promise) {
      result.catch(error => {
        const state = this.#state;
        if ((state.phase === "connecting" || state.phase === "connected") && state.connection === connection) {
          this.#onError(error, "send");
        }
      });
    }
  }
}

// Awareness emits application events during presence removal and destruction.
// A listener failure must not interrupt those operations or leave its timer alive.
class ProviderAwareness extends Awareness {
  constructor(doc: Doc, private readonly onError: (error: unknown, context: string) => void) {
    super(doc);
  }
  override emit(...args: Parameters<Awareness["emit"]>): void {
    try { super.emit(...args); }
    catch (error) { this.onError(error, `awareness:${args[0]}`); }
  }
}
