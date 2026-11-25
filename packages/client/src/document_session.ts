// Holds a document for the application, independently of editors and page
// navigation.
//
// A session remains open while an editor is attached or the server has not yet
// acknowledged some of its edits, and it closes itself when neither is true.
// When the server rejects the subscription, the session tries the descriptor's
// refresh URL once if it has one. If there is no URL, the refresh fails, or the
// server rejects the new grant, the session blocks. Blocking releases its
// editors and keeps its queued work in memory until the application calls
// retry() or discard().
import * as Y from "yjs";
import { uuidv4 } from "lib0/random";
import { ActionCableProvider, type CableConsumer, type ProviderStatus } from "./actioncable_provider.js";

export interface DocumentDescriptor {
  channel?: string;
  grant: string;
  name: string;
  /** A same-origin URL that returns `{ "grant": "..." }` for this document. The session fetches it at most once per rejection. */
  refresh?: string;
}
export type ResolvedDescriptor = Readonly<{ channel: string; grant: string; name: string; refresh?: string }>;
// "open" is the normal state, with or without editors attached. Check
// hasPending to see whether anything is still being delivered.
export type DocumentSessionState = "open" | "blocked" | "closed";
// Refreshing and renewed are substates of open, so editors and queued work
// persist through them. A renewed session can't refresh again until the
// transport accepts the new grant. A blocked or closed session has no renewal
// in progress.
type SessionPhase = "open" | "refreshing" | "renewed" | "blocked" | "closed";
type SessionLifecycle = Readonly<{ phase: SessionPhase }>;
type PhaseEvent = "refresh" | "renew" | "accept" | "block" | "retry" | "close";
// Each phase sets the state apps see, whether a new lease connects right away,
// and which transitions are allowed. A new lease does not connect while the
// session is blocked or waiting for a refreshed grant. Transitions that aren't
// listed are ignored.
const PHASES: Record<SessionPhase, {
  state: DocumentSessionState;
  connects: boolean;
  on: Partial<Record<PhaseEvent, SessionPhase>>;
}> = {
  open:       { state: "open",    connects: true,  on: { refresh: "refreshing", block: "blocked", close: "closed" } },
  refreshing: { state: "open",    connects: false, on: { renew: "renewed",      block: "blocked", close: "closed" } },
  renewed:    { state: "open",    connects: true,  on: { accept: "open",        block: "blocked", close: "closed" } },
  blocked:    { state: "blocked", connects: false, on: { retry: "open",                          close: "closed" } },
  closed:     { state: "closed",  connects: false, on: {} },
};
// Without a limit, a refresh request that never returns would leave the
// session offline and stuck with its editors attached. After this long, the
// session blocks.
const REFRESH_TIMEOUT_MS = 15_000;
const DEFAULT_CHANNEL = "Y::DocumentChannel";
const stores = new WeakMap<CableConsumer, DocumentSessionStore>();

/** The identity of the document a descriptor names. Matching keys share a session. */
export function documentKey(descriptor: DocumentDescriptor): string {
  return JSON.stringify([descriptor.channel || DEFAULT_CHANNEL, descriptor.grant, descriptor.name]);
}

// Only the factory may create a store for a consumer.
const storeToken = Symbol("storeToken");
// Not exported, so only the store can acquire leases.
const attachLease = Symbol("attachLease");
// Not exported, so only a session can publish store changes.
const notifyStoreChange = Symbol("notifyStoreChange");

/** Holds one consumer's sessions and emits "change" with the session in `detail`. */
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
    // The refresh URL is not part of the identity. Matching tuples share a
    // session, which renews with the URL from the first acquisition.
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

/** A caller's hold on a session. Release it when you're done with the session. */
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
  /** Runs editor cleanup synchronously, before the final check for pending work. */
  release(): void {
    if (this.signal.aborted) return;
    this.#controller.abort();
    this.#onRelease();
  }
}

// Application commands (acquire, retry, discard) take effect immediately.
// Provider callbacks and lease releases record what happened and request a
// settle, which runs after the current call stack finishes. Settle releases a
// blocked session's leases, closes a session nobody needs, and notifies store
// observers once.
export class DocumentSession {
  readonly doc = new Y.Doc();
  readonly provider: ActionCableProvider;
  #lifecycle: SessionLifecycle = { phase: "open" };
  #leases = new Set<DocumentLease>();
  // Leases held when the session blocked. Settle releases these and keeps any
  // lease acquired while blocked for retry().
  #retiring: DocumentLease[] | undefined;
  #error: unknown;
  #dirty = false; // true until store observers are notified of the latest change
  #settleQueued = false;

  /** Create and hold sessions through DocumentSessionStore.acquire. */
  constructor(
    readonly store: DocumentSessionStore,
    readonly descriptor: ResolvedDescriptor,
    private readonly remove: () => void,
  ) {
    // The session uses one provider for its whole life. The provider queues
    // edits while offline, so blocking and retrying only need to disconnect and
    // connect.
    this.provider = new ActionCableProvider(this.doc, store.consumer, descriptor.channel, {
      grant: descriptor.grant,
      name: descriptor.name,
      // Ack sequence numbers are per session, not per record.
      session_id: uuidv4(),
    }, {
      onError: (error, context) => {
        if (context === "rejected") this.#rejected(error);
        else if (this.state !== "closed") { this.#error = error; this.#changed(); }
      },
    });
    this.provider.awareness.setLocalState(null); // no cursor until an editor sets one
    this.provider.onStatusChange(({ status }) => {
      if (this.state !== "open") return;
      // The server accepted the subscription, so a renewed grant is valid.
      if (status === "connected" || status === "synced") this.#transition("accept");
      this.#changed();
    });
  }
  get error(): unknown { return this.#error; }
  get hasPending(): boolean { return this.provider.hasPending; }
  get whenSynced(): Promise<void> { return this.provider.whenSynced; }
  get state(): DocumentSessionState { return PHASES[this.#lifecycle.phase].state; }

  [attachLease](): DocumentLease {
    if (this.state === "closed") throw new Error("Cannot acquire a closed document session");
    const lease = new DocumentLease(this, () => this.#release(lease));
    this.#leases.add(lease);
    this.#changed();
    if (PHASES[this.#lifecycle.phase].connects) this.#connect();
    return lease;
  }
  #release(lease: DocumentLease): void {
    if (!this.#leases.delete(lease)) return;
    this.#changed();
    if (!this.#leases.size) this.provider.awareness.setLocalState(null);
  }
  /** Reconnects with this session's current grant, which is the original one or the last one a refresh returned. */
  retry(): void {
    if (this.#transition("retry")) this.#connect();
  }
  /** Closes the session and drops pending work. The application calls this explicitly, because an ordinary detach keeps pending work. */
  discard(): void { this.#close(); }

  #changed(): void {
    this.#dirty = true;
    if (this.#settleQueued) return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle(): void {
    this.#settleQueued = false;
    // If editor cleanup retries or blocks during #enforce, #changed queues
    // another settle to handle it.
    this.#enforce();
    if (!this.#dirty) return;
    this.#dirty = false;
    this.store[notifyStoreChange](this);
  }
  #enforce(): void {
    if (this.state === "closed") return;
    if (this.state === "blocked") {
      const retiring = this.#retiring;
      this.#retiring = undefined;
      // Leave the queue alone until retry() or discard().
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

  // The only method that changes the phase. It doesn't call out to other code,
  // and #settle acts on the result.
  #transition(event: PhaseEvent, error?: unknown): boolean {
    const phase = PHASES[this.#lifecycle.phase].on[event];
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
    // Leave the store first so editor cleanup below can acquire a new session.
    this.remove();
    for (const lease of [...this.#leases]) lease.release();
    this.provider.destroy();
    this.doc.destroy();
  }
  // Try the refresh URL once per rejection. Block if the server rejects again
  // while refreshing or rejects the renewed grant.
  #rejected(error: unknown): void {
    const url = this.descriptor.refresh;
    if (url && this.#transition("refresh")) void this.#refresh(url, this.#lifecycle);
    else this.#transition("block", error);
  }
  async #refresh(url: string, attempt: SessionLifecycle): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      if (this.#lifecycle === attempt) this.#transition("block", error);
      return;
    }
    // A retry, discard, or block during the request takes precedence over it.
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
