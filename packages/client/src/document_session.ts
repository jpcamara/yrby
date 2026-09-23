// Application document ownership, independent of editors and page navigation.
//
// A session lives while something still needs it: an editor attached to it,
// or edits the server has not acknowledged. Once neither remains it closes
// itself. After a subscription rejection, the session tries the descriptor's
// refresh URL once, if provided. If no URL exists, the refresh fails, or the
// new grant is rejected, it blocks: editors are released, work stays queued
// in memory, and the application chooses between retry() and discard().
import * as Y from "yjs";
import { uuidv4 } from "lib0/random";
import { ActionCableProvider, type CableConsumer, type ProviderStatus } from "./actioncable_provider.js";

export interface DocumentDescriptor {
  channel?: string;
  grant: string;
  name: string;
  /** A same-origin URL that returns `{ "grant": "..." }` for this document. Used once per rejection. */
  refresh?: string;
}
export type ResolvedDescriptor = Readonly<{ channel: string; grant: string; name: string; refresh?: string }>;
// "open" is the normal state, with or without editors attached; see hasPending
// for whether anything is still being delivered.
export type DocumentSessionState = "open" | "blocked" | "closed";
// Refreshing and renewed are open substates: editors and queued work survive.
// "renewed" waits for the transport to accept the new grant before another
// refresh is allowed. Blocked and closed cannot have a renewal in progress.
type SessionPhase = "open" | "refreshing" | "renewed" | "blocked" | "closed";
type SessionLifecycle = Readonly<{ phase: SessionPhase }>;
type PhaseEvent = "refresh" | "renew" | "accept" | "block" | "retry" | "close";
const TRANSITIONS: Record<SessionPhase, Partial<Record<PhaseEvent, SessionPhase>>> = {
  open:       { refresh: "refreshing", block: "blocked", close: "closed" },
  refreshing: { renew: "renewed",      block: "blocked", close: "closed" },
  renewed:    { accept: "open",        block: "blocked", close: "closed" },
  blocked:    { retry: "open",                          close: "closed" },
  closed:     {},
};
// A refresh request that never answers would leave the session offline with
// its editors attached and no way forward. After this long it blocks instead.
const REFRESH_TIMEOUT_MS = 15_000;
const stores = new WeakMap<CableConsumer, DocumentSessionStore>();
// Only the factory may create a store for a consumer.
const storeToken = Symbol("storeToken");
// Only the store acquires leases; this symbol is not exported.
const attachLease = Symbol("attachLease");
// Only a session publishes store changes; this symbol is not exported.
const notifyStoreChange = Symbol("notifyStoreChange");

/** The sessions of one consumer. Emits "change" with the session in `detail`. */
export class DocumentSessionStore extends EventTarget {
  static for(consumer: CableConsumer): DocumentSessionStore {
    let store = stores.get(consumer);
    if (!store) stores.set(consumer, store = new DocumentSessionStore(consumer, storeToken));
    return store;
  }
  #sessions = new Map<string, DocumentSession>();
  private constructor(readonly consumer: CableConsumer, token: typeof storeToken) {
    super();
    if (token !== storeToken) throw new Error("Use DocumentSessionStore.for(consumer)");
  }
  get sessions(): readonly DocumentSession[] { return [...this.#sessions.values()]; }

  /** Acquire a lease on this document session, creating it on first use. */
  acquire(input: DocumentDescriptor): DocumentLease {
    if (!input.grant || !input.name) throw new Error("A document requires a grant and name");
    // The refresh URL is not part of the identity: matching tuples share a
    // session, and the first acquirer's URL is the one that session renews with.
    const descriptor: ResolvedDescriptor = Object.freeze({
      channel: input.channel || "Y::DocumentChannel",
      grant: input.grant,
      name: input.name,
      ...(input.refresh ? { refresh: input.refresh } : {}),
    });
    const key = JSON.stringify([descriptor.channel, descriptor.grant, descriptor.name]);
    let session = this.#sessions.get(key);
    if (!session) {
      session = new DocumentSession(this, descriptor, () => { this.#sessions.delete(key); });
      this.#sessions.set(key, session);
    }
    return session[attachLease]();
  }
  [notifyStoreChange](session: DocumentSession): void {
    this.dispatchEvent(new CustomEvent("change", { detail: session }));
  }
}

/** A caller's hold on a session. Release it when the caller is finished. */
export class DocumentLease {
  #controller = new AbortController();
  #onRelease: () => void;
  constructor(readonly session: DocumentSession, onRelease: () => void) {
    this.#onRelease = onRelease;
  }
  /** Aborts when the lease ends, including when the session blocks or is discarded. */
  get signal(): AbortSignal { return this.#controller.signal; }
  setPresence(state: Record<string, unknown> | null): void {
    if (!this.signal.aborted) this.session.provider.awareness.setLocalState(state);
  }
  /** Editor cleanup runs synchronously before the final pending-work check. */
  release(): void {
    if (this.signal.aborted) return;
    this.#controller.abort();
    this.#onRelease();
  }
}

export class DocumentSession {
  readonly doc = new Y.Doc();
  readonly provider: ActionCableProvider;
  #lifecycle: SessionLifecycle = { phase: "open" };
  #leases = new Set<DocumentLease>();
  #error: unknown;
  #notificationDepth = 0;
  #notificationPending = false;

  /** Use DocumentSessionStore.acquire to create and own sessions. */
  constructor(
    readonly store: DocumentSessionStore,
    readonly descriptor: ResolvedDescriptor,
    private readonly remove: () => void,
  ) {
    // One provider for the session's whole life. It queues edits while offline,
    // so blocking and retrying are just disconnect and connect.
    this.provider = new ActionCableProvider(this.doc, store.consumer, descriptor.channel, {
      grant: descriptor.grant,
      name: descriptor.name,
      // Ack sequence numbers belong to this session, not a record.
      session_id: uuidv4(),
    }, {
      onError: (error, context) => this.#batchChanges(() => {
        if (context === "rejected") this.#rejected(error);
        else this.#recordError(error);
      }),
    });
    this.provider.awareness.setLocalState(null); // no cursor until an editor sets one
    this.provider.onStatusChange(({ status }) => this.#batchChanges(() => this.#status(status)));
  }
  get error(): unknown { return this.#error; }
  get hasPending(): boolean { return this.provider.hasPending; }
  get whenSynced(): Promise<void> { return this.provider.whenSynced; }
  get state(): DocumentSessionState {
    const { phase } = this.#lifecycle;
    return phase === "refreshing" || phase === "renewed" ? "open" : phase;
  }

  [attachLease](): DocumentLease {
    return this.#batchChanges(() => {
      const current = this.#lifecycle;
      if (current.phase === "closed") throw new Error("Cannot acquire a closed document session");
      const lease = new DocumentLease(this, () => this.#release(lease));
      this.#leases.add(lease);
      this.#markChanged();
      if (current.phase === "open" || current.phase === "renewed") this.#connect(current);
      if (this.#lifecycle === current) this.#closeIfIdle();
      return lease;
    });
  }
  #release(lease: DocumentLease): void {
    this.#batchChanges(() => {
      const current = this.#lifecycle;
      if (!this.#leases.delete(lease)) return;
      if (!this.#leases.size) this.provider.awareness.setLocalState(null);
      if (current.phase === "blocked" || current.phase === "closed" || this.#lifecycle !== current) return;
      this.#markChanged();
      this.#closeIfIdle();
    });
  }
  /** Retry with this session's current grant: the original one, or the last one a refresh returned. */
  retry(): void {
    this.#batchChanges(() => {
      const next = this.#transition("retry");
      if (!next) return;
      this.#connect(next);
      if (this.#lifecycle === next) this.#closeIfIdle();
    });
  }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void { this.#batchChanges(() => { this.#transition("close"); }); }

  // Callbacks can synchronously release leases, retry, or acquire replacements.
  // Observers see the result only after the outermost operation is complete.
  #batchChanges<T>(operation: () => T): T {
    this.#notificationDepth++;
    try {
      return operation();
    } finally {
      if (--this.#notificationDepth === 0 && this.#notificationPending) {
        this.#notificationPending = false;
        this.store[notifyStoreChange](this);
      }
    }
  }
  #markChanged(): void { this.#notificationPending = true; }

  // This is the only place that changes the phase.
  #transition(event: PhaseEvent, error?: unknown): SessionLifecycle | undefined {
    const phase = TRANSITIONS[this.#lifecycle.phase][event];
    if (!phase) return;
    const next = this.#lifecycle = { phase };
    if (event === "retry") this.#error = undefined;
    else if (event === "block") this.#error = error;
    this.#markChanged();
    if (phase === "blocked" || phase === "closed") {
      // Snapshot before cleanup callbacks can retry or acquire a replacement.
      const retiring = [...this.#leases];
      if (phase === "blocked") this.provider.disconnect();
      else this.remove();
      for (const lease of retiring) lease.release();
      if (phase === "closed") {
        this.provider.destroy();
        this.doc.destroy();
      }
    }
    return next;
  }
  #closeIfIdle(): void {
    if (this.#lifecycle.phase !== "blocked" && this.#lifecycle.phase !== "closed" &&
        !this.#leases.size && !this.provider.hasPending) this.#transition("close");
  }
  #connect(from: SessionLifecycle, grant?: string): void {
    try {
      if (grant === undefined) this.provider.connect();
      else this.provider.renew({ grant });
    } catch (error) {
      this.#failed(from, error);
    }
  }
  #status(status: ProviderStatus): void {
    const { phase } = this.#lifecycle;
    if (phase === "blocked" || phase === "closed") return;
    if (phase === "renewed" && (status === "connected" || status === "synced")) this.#transition("accept");
    else this.#markChanged();
    this.#closeIfIdle();
  }
  #rejected(error: unknown): void {
    const { phase } = this.#lifecycle;
    if (phase === "blocked" || phase === "closed") return;
    if (phase === "open" && this.descriptor.refresh) {
      const attempt = this.#transition("refresh");
      if (attempt) void this.#refresh(this.descriptor.refresh, attempt);
      if (this.#lifecycle === attempt) this.#closeIfIdle();
    } else {
      this.#transition("block", error);
    }
  }
  #failed(from: SessionLifecycle, error: unknown): void {
    if (this.#lifecycle === from) this.#transition("block", error);
  }
  #recordError(error: unknown): void {
    if (this.#lifecycle.phase === "closed") return;
    this.#error = error;
    this.#markChanged();
  }
  async #refresh(url: string, from: SessionLifecycle): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      this.#batchChanges(() => this.#failed(from, error));
      return;
    }
    this.#batchChanges(() => {
      if (this.#lifecycle !== from) return;
      const next = this.#transition("renew");
      if (!next) return;
      this.#connect(next, grant);
      if (this.#lifecycle === next) this.#closeIfIdle();
    });
  }
}

/** Ask the application for a new grant. Resolves to the grant or throws. */
async function fetchGrant(url: string): Promise<string> {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    signal: AbortSignal.timeout(REFRESH_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`grant refresh failed: ${response.status}`);
  const body: unknown = await response.json();
  const grant = (body as { grant?: unknown } | null)?.grant;
  if (typeof grant !== "string" || !grant) throw new Error("grant refresh returned no grant");
  return grant;
}
