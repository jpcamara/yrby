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

// One connect() call. Cable callbacks carry the attempt that created them, so
// callbacks from a retired subscription cannot touch a newer one.
type Attempt = object;
type StopReason = "disconnect" | "reject" | "destroy";
type ProviderState =
  | { phase: "disconnected" | "destroyed" }
  | { phase: "subscribing"; attempt: Attempt }
  | { phase: "connecting" | "connected"; attempt: Attempt; subscription: CableSubscription }
  // Presence removal and unsubscribe are running. A destroy() meanwhile upgrades the reason.
  | { phase: "stopping"; attempt: Attempt; subscription: CableSubscription; reason: StopReason };

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
    if (this.#destroying()) throw new Error("provider is destroyed");
    if (this.#state.phase !== "disconnected") return;
    const attempt: Attempt = {};
    this.#state = { phase: "subscribing", attempt };
    // A consumer may call back inside create(), before the subscription is
    // installed. Those callbacks wait one microtask.
    const on = <A extends unknown[]>(callback: (...args: A) => void) => (...args: A): void => {
      const run = () => { if (this.#active(attempt)) callback(...args); };
      if (this.#state.phase === "subscribing") queueMicrotask(run);
      else run();
    };
    let subscription: CableSubscription;
    try {
      subscription = this.consumer.subscriptions.create(
        { channel: this.channelName, ...this.channelParams },
        {
          received: on((message: CableMessage) => this.#receive(message, attempt)),
          connected: on(() => this.#connected()),
          disconnected: on(() => this.#lost()),
          rejected: on(() => this.#stop("reject")),
        }
      );
    } catch (error) {
      if (!this.#subscribing(attempt)) return;
      this.#state = { phase: "disconnected" };
      this.#refreshStatus();
      throw error;
    }
    // disconnect() or destroy() ran inside create().
    if (!this.#subscribing(attempt)) { this.#unsubscribe(subscription); return; }
    this.#state = { phase: "connecting", attempt, subscription };
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
    if (this.#destroying()) return;
    Object.assign(this.channelParams, params);
    this.disconnect();
    this.connect();
  }

  destroy(): void { this.#stop("destroy"); }

  #destroying(): boolean {
    const state = this.#state;
    return state.phase === "destroyed" || (state.phase === "stopping" && state.reason === "destroy");
  }
  #subscribing(attempt: Attempt): boolean {
    return this.#state.phase === "subscribing" && this.#state.attempt === attempt;
  }
  // Only a connecting or connected subscription hears its cable callbacks.
  #active(attempt: Attempt): boolean {
    const state = this.#state;
    return (state.phase === "connecting" || state.phase === "connected") && state.attempt === attempt;
  }
  // Cable callbacks below run only for the active attempt; on() in connect() checks.
  #connected(): void {
    const state = this.#state;
    if (state.phase !== "connecting") return;
    this.#state = { ...state, phase: "connected" };
    this.session.resume();
    this.#refreshStatus();
  }
  #lost(): void {
    const state = this.#state;
    if (state.phase !== "connecting" && state.phase !== "connected") return;
    this.#state = { ...state, phase: "connecting" };
    this.session.pause();
    this.#refreshStatus();
  }
  #stop(reason: StopReason): void {
    const state = this.#state;
    if (state.phase === "destroyed") return;
    if (state.phase === "stopping") {
      if (reason === "destroy") state.reason = reason;
      return;
    }
    if (state.phase === "disconnected" && reason === "disconnect") return;
    let finalReason = reason;
    if ("subscription" in state) {
      const stopping = { ...state, phase: "stopping" as const, reason };
      this.#state = stopping;
      this.#unwatchPage();
      // Retired callbacks are silent, but the old subscription can still
      // send presence removal before its deferred unsubscribe.
      this.session.removeLocalAwareness();
      this.session.pause();
      this.#unsubscribe(state.subscription);
      if (this.#state !== stopping) return;
      finalReason = stopping.reason; // a destroy() during those calls upgrades it
    }
    const destroyed = finalReason === "destroy";
    this.#state = { phase: destroyed ? "destroyed" : "disconnected" };
    if (destroyed) this.#destroyOwned();
    else if (finalReason === "reject") this.#onError(new Error("subscription rejected by the server"), "rejected");
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

  #receive(message: CableMessage, attempt: Attempt): void {
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
    // Applying the frame runs doc observers, which may have replaced the connection.
    if (reply && this.#active(attempt)) this.#send(reply, undefined);
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
    if (!("subscription" in state)) return;
    const isAwareness = frame[0] === MessageType.Awareness;
    if (state.phase === "stopping" && !isAwareness) return;
    const { subscription } = state;
    const update = toBase64(frame);
    // Route transport failures (sync throws, or @anycable/web's rejected
    // promises) to onError instead of letting them escape into update
    // handlers. A failed send is recoverable: reliable frames stay queued
    // until acked, and awareness is best-effort anyway. A failure from a
    // subscription that has since been replaced is not reported.
    const report = (error: unknown) => {
      const current = this.#state;
      if ("subscription" in current && current.subscription === subscription) this.#onError(error, "send");
    };
    try {
      const result = isAwareness && typeof subscription.whisper === "function"
        ? subscription.whisper({ awareness: update })
        : subscription.send(id === undefined ? { update } : { update, id });
      if (result instanceof Promise) result.catch(report);
    } catch (error) {
      report(error);
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
