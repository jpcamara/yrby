// Application document ownership, independent of editors and page navigation.
//
// A session lives while something still needs it: an editor attached to it,
// or edits the server has not acknowledged. Once neither remains it closes
// itself. When the server rejects the subscription, the session asks the
// application for a fresh grant once (through the descriptor's refresh URL),
// then blocks: editors are released, the work stays queued in memory, and the
// application chooses between retry() and discard().
import * as Y from "yjs";
import { uuidv4 } from "lib0/random";
import { ActionCableProvider, type CableConsumer } from "./actioncable_provider.js";

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
// One grant refresh per rejection. "fetching" while the request is in flight,
// "spent" once it was used, back to "idle" when the transport comes up again,
// so a renewed grant that is rejected in turn blocks instead of looping.
type Renewal = "idle" | "fetching" | "spent";
// A refresh request that never answers would leave the session offline with
// its editors attached and no way forward. After this long it blocks instead.
const REFRESH_TIMEOUT_MS = 15_000;
const stores = new WeakMap<CableConsumer, DocumentSessionStore>();

/** The sessions of one consumer. Emits "change" with the session in `detail`. */
export class DocumentSessionStore extends EventTarget {
  static for(consumer: CableConsumer): DocumentSessionStore {
    let store = stores.get(consumer);
    if (!store) stores.set(consumer, store = new DocumentSessionStore(consumer));
    return store;
  }
  #sessions = new Map<string, DocumentSession>();
  constructor(readonly consumer: CableConsumer) { super(); }
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
    return session.attach();
  }
  /** @internal */
  changed(session: DocumentSession): void {
    this.dispatchEvent(new CustomEvent("change", { detail: session }));
  }
}

/** A caller's hold on a session. Release it when the caller is finished. */
export class DocumentLease {
  #controller = new AbortController();
  #released = false;
  constructor(readonly session: DocumentSession) {}
  /** Aborts when the lease ends, including when the session blocks or is discarded. */
  get signal(): AbortSignal { return this.#controller.signal; }
  setPresence(state: Record<string, unknown> | null): void {
    if (!this.#released) this.session.provider.awareness.setLocalState(state);
  }
  /** Editor cleanup runs synchronously before the final pending-work check. */
  release(): void {
    if (this.#released) return;
    this.#released = true;
    this.#controller.abort();
    this.session.release(this);
  }
}

export class DocumentSession {
  readonly doc = new Y.Doc();
  readonly provider: ActionCableProvider;
  #phase: DocumentSessionState = "open";
  #renewal: Renewal = "idle";
  #leases = new Set<DocumentLease>();
  #error: unknown;

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
        else { this.#error = error; this.store.changed(this); }
      },
    });
    this.provider.awareness.setLocalState(null); // no cursor until an editor sets one
    this.provider.onStatusChange(({ status }) => {
      const up = status === "connected" || status === "synced";
      if (up && this.#renewal === "spent") this.#renewal = "idle";
      this.#settle(); // also fires when the pending queue empties
    });
  }
  get error(): unknown { return this.#error; }
  get hasPending(): boolean { return this.provider.hasPending; }
  get whenSynced(): Promise<void> { return this.provider.whenSynced; }
  get state(): DocumentSessionState { return this.#phase; }

  /** @internal */
  attach(): DocumentLease {
    const lease = new DocumentLease(this);
    this.#leases.add(lease);
    this.#connect();
    this.store.changed(this);
    return lease;
  }
  /** @internal */
  release(lease: DocumentLease): void {
    this.#leases.delete(lease);
    if (!this.#leases.size) this.provider.awareness.setLocalState(null);
    this.#settle();
  }
  /** Retry with this session's current grant: the original one, or the last one a refresh returned. */
  retry(): void {
    if (this.#phase !== "blocked") return;
    this.#phase = "open";
    this.#error = undefined;
    this.#renewal = "idle";
    this.#connect();
    this.#settle();
  }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void {
    this.#end("closed");
  }

  // The only place the phase changes after construction, and the two ways an
  // open session stops: blocked keeps the work in the queue for retry(),
  // closed throws it away. Both end every lease first, because an editor's
  // teardown can flush one last edit, and both notify exactly once.
  #end(phase: "blocked" | "closed", error?: unknown): void {
    if (this.#phase === phase || this.#phase === "closed") return;
    if (phase === "blocked" && this.#phase !== "open") return;
    this.#phase = phase;
    if (error !== undefined) this.#error = error;
    for (const lease of this.#leases) lease.release();
    if (phase === "blocked") this.provider.disconnect();
    else this.#dispose();
    this.store.changed(this);
  }

  #connect(): void {
    if (this.#phase !== "open") return;
    try {
      this.provider.connect();
    } catch (error) {
      this.#block(error);
    }
  }
  // The server refused the subscription. With a refresh URL and no renewal
  // since the transport last came up, ask for a new grant and resubscribe
  // with it. Otherwise, or if that fails, block.
  #rejected(error: unknown): void {
    const refresh = this.descriptor.refresh;
    if (!refresh || this.#renewal !== "idle") { this.#block(error); return; }
    this.#renewal = "fetching";
    void this.#renew(refresh);
  }
  async #renew(refresh: string): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(refresh);
    } catch (error) {
      this.#renewal = "spent";
      this.#block(error);
      return;
    }
    this.#renewal = "spent";
    if (this.#phase !== "open") return; // blocked or discarded during the fetch
    try {
      this.provider.renew({ grant });
    } catch (error) {
      this.#block(error); // the consumer refused to create the subscription
      return;
    }
    this.store.changed(this);
  }
  #block(error: unknown): void {
    this.#end("blocked", error);
  }
  // Close once nothing needs the session: no leases and nothing unacknowledged.
  // Only an open session has anything to report; blocked and closed announce
  // themselves through #end.
  #settle(): void {
    if (this.#phase !== "open") return;
    if (!this.#leases.size && !this.provider.hasPending) {
      this.#end("closed");
      return;
    }
    this.store.changed(this);
  }
  // Teardown only; #end does the notifying.
  #dispose(): void {
    this.remove();
    this.provider.destroy();
    this.doc.destroy();
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
