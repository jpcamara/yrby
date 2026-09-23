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
type SessionEvent =
  | { type: "acquire" | "retry" | "discard" }
  | { type: "release"; lease: DocumentLease }
  | { type: "status"; status: ProviderStatus }
  | { type: "rejected" | "error"; error: unknown }
  | { type: "refreshed"; from: SessionLifecycle; grant: string }
  | { type: "failed"; from: SessionLifecycle; error: unknown };
type SessionEffect =
  | { type: "connect"; grant?: string }
  | { type: "refresh"; url: string };
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
  #transitionDepth = 0;
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
      onError: (error, context) => this.#transition({ type: context === "rejected" ? "rejected" : "error", error }),
    });
    this.provider.awareness.setLocalState(null); // no cursor until an editor sets one
    this.provider.onStatusChange(({ status }) => this.#transition({ type: "status", status }));
  }
  get error(): unknown { return this.#error; }
  get hasPending(): boolean { return this.provider.hasPending; }
  get whenSynced(): Promise<void> { return this.provider.whenSynced; }
  get state(): DocumentSessionState {
    const { phase } = this.#lifecycle;
    return phase === "refreshing" || phase === "renewed" ? "open" : phase;
  }

  [attachLease](): DocumentLease { return this.#transition({ type: "acquire" }); }
  /** Retry with this session's current grant: the original one, or the last one a refresh returned. */
  retry(): void { this.#transition({ type: "retry" }); }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void { this.#transition({ type: "discard" }); }

  #transition(event: { type: "acquire" }): DocumentLease;
  #transition(event: SessionEvent): void;
  #transition(event: SessionEvent): DocumentLease | void {
    this.#transitionDepth++;
    try {
      const current = this.#lifecycle;
      // Closing still releases existing leases, but cannot acquire new ones.
      if (current.phase === "closed" && event.type !== "release") {
        if (event.type === "acquire") throw new Error("Cannot acquire a closed document session");
        return;
      }
      let next = current;
      let effect: SessionEffect | undefined;
      let lease: DocumentLease | undefined;
      switch (event.type) {
        case "acquire": {
          const acquired = new DocumentLease(this, () => this.#transition({ type: "release", lease: acquired }));
          this.#leases.add(acquired);
          lease = acquired;
          if (current.phase === "open" || current.phase === "renewed") effect = { type: "connect" };
          break;
        }
        case "release":
          if (!this.#leases.delete(event.lease)) return;
          if (!this.#leases.size) this.provider.awareness.setLocalState(null);
          if (current.phase === "blocked" || current.phase === "closed") return;
          break;
        case "retry":
          if (current.phase !== "blocked") return;
          next = { phase: "open" };
          this.#error = undefined;
          effect = { type: "connect" };
          break;
        case "discard":
          next = { phase: "closed" };
          break;
        case "status":
          if (current.phase === "blocked") return;
          if (current.phase === "renewed" && (event.status === "connected" || event.status === "synced")) {
            next = { phase: "open" };
          }
          break;
        case "rejected":
          if (current.phase === "blocked") return;
          if (current.phase === "open" && this.descriptor.refresh) {
            next = { phase: "refreshing" };
            effect = { type: "refresh", url: this.descriptor.refresh };
          } else {
            next = { phase: "blocked" };
            this.#error = event.error;
          }
          break;
        case "refreshed":
          if (current !== event.from || current.phase !== "refreshing") return;
          next = { phase: "renewed" };
          effect = { type: "connect", grant: event.grant };
          break;
        case "failed":
          if (current !== event.from || current.phase === "blocked") return;
          next = { phase: "blocked" };
          this.#error = event.error;
          break;
        case "error":
          this.#error = event.error;
          this.#notificationPending = true;
          return;
        default: {
          const unhandled: never = event;
          throw new Error(`Unhandled document session event: ${unhandled}`);
        }
      }
      // Presence callbacks during release can already have ended this lifetime.
      if (this.#lifecycle !== current) return lease;
      this.#lifecycle = next;
      this.#notificationPending = true;

      if (next !== current && (next.phase === "blocked" || next.phase === "closed")) {
        // Snapshot before callbacks can retry and acquire replacement leases.
        const retiring = [...this.#leases];
        if (next.phase === "blocked") this.provider.disconnect();
        else this.remove(); // replacement acquisition must find a new session
        for (const owned of retiring) owned.release();
        if (next.phase === "closed") {
          this.provider.destroy();
          this.doc.destroy();
        }
        return lease;
      }
      if (effect?.type === "connect") this.#connect(next, effect.grant);
      else if (effect?.type === "refresh") void this.#refresh(effect.url, next);
      if (this.#lifecycle !== next) return lease;

      // An open lifetime ends only after both ownership and delivery are done.
      if (next.phase !== "blocked" && next.phase !== "closed" && !this.#leases.size && !this.provider.hasPending) {
        this.#transition({ type: "discard" });
      }
      return lease;
    } finally {
      // Nested provider/lease callbacks finish before observers see the result.
      if (--this.#transitionDepth === 0 && this.#notificationPending) {
        this.#notificationPending = false;
        this.store[notifyStoreChange](this);
      }
    }
  }

  #connect(from: SessionLifecycle, grant?: string): void {
    try {
      if (grant === undefined) this.provider.connect();
      else this.provider.renew({ grant });
    } catch (error) {
      this.#transition({ type: "failed", from, error });
    }
  }
  async #refresh(url: string, from: SessionLifecycle): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(url);
    } catch (error) {
      this.#transition({ type: "failed", from, error });
      return;
    }
    this.#transition({ type: "refreshed", from, grant });
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
