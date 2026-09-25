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
const DEFAULT_CHANNEL = "Y::DocumentChannel";
const stores = new WeakMap<CableConsumer, DocumentSessionStore>();

/** The identity of the document a descriptor names. Matching keys share a session. */
export function documentKey(descriptor: DocumentDescriptor): string {
  return JSON.stringify([descriptor.channel || DEFAULT_CHANNEL, descriptor.grant, descriptor.name]);
}

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
      channel: input.channel || DEFAULT_CHANNEL,
      grant: input.grant,
      name: input.name,
      ...(input.refresh ? { refresh: input.refresh } : {}),
    });
    const key = documentKey(descriptor);
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

// Application commands (acquire, retry, discard) act immediately. Provider
// callbacks and lease releases only record what happened and ask for a settle,
// which runs once the current call stack has finished: it retires the leases
// of a blocked session, closes a session nobody needs, and tells store
// observers once.
export class DocumentSession {
  readonly doc = new Y.Doc();
  readonly provider: ActionCableProvider;
  #lifecycle: SessionLifecycle = { phase: "open" };
  #leases = new Set<DocumentLease>();
  // The leases held when the session blocked. Settle releases them; a lease
  // acquired while blocked is kept for retry().
  #retiring: DocumentLease[] | undefined;
  #error: unknown;
  #dirty = false; // observers have not heard about the latest change
  #settleQueued = false;

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
      onError: (error, context) => {
        if (context === "rejected") this.#rejected(error);
        else if (this.#lifecycle.phase !== "closed") { this.#error = error; this.#changed(); }
      },
    });
    this.provider.awareness.setLocalState(null); // no cursor until an editor sets one
    this.provider.onStatusChange(({ status }) => {
      const { phase } = this.#lifecycle;
      if (phase === "closed" || phase === "blocked") return;
      // A renewed grant is accepted once the server lets it connect.
      if (phase === "renewed" && (status === "connected" || status === "synced")) this.#transition("accept");
      this.#changed();
    });
  }
  get error(): unknown { return this.#error; }
  get hasPending(): boolean { return this.provider.hasPending; }
  get whenSynced(): Promise<void> { return this.provider.whenSynced; }
  get state(): DocumentSessionState {
    const { phase } = this.#lifecycle;
    return phase === "refreshing" || phase === "renewed" ? "open" : phase;
  }

  [attachLease](): DocumentLease {
    if (this.#lifecycle.phase === "closed") throw new Error("Cannot acquire a closed document session");
    const lease = new DocumentLease(this, () => this.#release(lease));
    this.#leases.add(lease);
    this.#changed();
    const { phase } = this.#lifecycle;
    if (phase === "open" || phase === "renewed") this.#connect();
    return lease;
  }
  #release(lease: DocumentLease): void {
    if (!this.#leases.delete(lease)) return;
    this.#changed();
    if (!this.#leases.size) this.provider.awareness.setLocalState(null);
  }
  /** Retry with this session's current grant: the original one, or the last one a refresh returned. */
  retry(): void {
    if (this.#transition("retry")) this.#connect();
  }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void { this.#close(); }

  #changed(): void {
    this.#dirty = true;
    if (this.#settleQueued) return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle(): void {
    this.#settleQueued = false;
    let lifecycle: SessionLifecycle;
    do {
      lifecycle = this.#lifecycle;
      this.#enforce(lifecycle.phase);
    } while (this.#lifecycle !== lifecycle); // cleanup may have retried or blocked
    if (!this.#dirty) return;
    this.#dirty = false;
    this.store[notifyStoreChange](this);
  }
  #enforce(phase: SessionPhase): void {
    if (phase === "closed") return;
    if (phase === "blocked") {
      const retiring = this.#retiring;
      this.#retiring = undefined;
      // The queue stays until retry() or discard().
      for (const lease of retiring ?? []) lease.release();
      return;
    }
    if (!this.#needed()) this.#close();
  }
  // Connect with the current grant, or resubscribe with a renewed one. The
  // provider defers its own callbacks, so a failure here only blocks.
  #connect(grant?: string): void {
    try {
      if (grant === undefined) this.provider.connect();
      else this.provider.renew({ grant });
    } catch (error) {
      this.#transition("block", error);
    }
  }
  #needed(): boolean { return this.#leases.size > 0 || this.provider.hasPending; }

  // The only place that changes the phase. It never calls out; #settle acts on it.
  #transition(event: PhaseEvent, error?: unknown): boolean {
    const phase = TRANSITIONS[this.#lifecycle.phase][event];
    if (!phase) return false;
    this.#lifecycle = { phase };
    this.#retiring = phase === "blocked" ? [...this.#leases] : undefined;
    if (event === "retry") this.#error = undefined;
    else if (event === "block") this.#error = error;
    this.#changed();
    return true;
  }
  #close(): void {
    if (!this.#transition("close")) return;
    // Leave the store first, so editor cleanup below can acquire a fresh session.
    this.remove();
    for (const lease of [...this.#leases]) lease.release();
    this.provider.destroy();
    this.doc.destroy();
  }
  // Try the refresh URL once per rejection. A rejection while refreshing, or
  // of the renewed grant, blocks.
  #rejected(error: unknown): void {
    const url = this.descriptor.refresh;
    if (this.#lifecycle.phase === "open" && url) {
      this.#transition("refresh");
      void this.#refresh(url, this.#lifecycle);
    } else {
      this.#transition("block", error);
    }
  }
  async #refresh(url: string, attempt: SessionLifecycle): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      if (this.#lifecycle === attempt) this.#transition("block", error);
      return;
    }
    // A retry, discard, or block while the request was out owns the session now.
    if (this.#lifecycle !== attempt) return;
    if (this.#transition("renew")) this.#connect(grant);
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
