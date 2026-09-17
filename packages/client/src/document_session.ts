// Application document ownership, independent of editors and page navigation.
//
// A session lives while something still needs it: an editor attached to it,
// or edits the server has not acknowledged. Once neither remains it closes
// itself. When the server rejects the subscription, the session asks the
// application for a fresh grant once (through the descriptor's refresh URL),
// then blocks: editors are released, the work stays in memory, and the
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
export type DocumentSessionState = "attached" | "draining" | "blocked" | "closed";
export interface DocumentRecovery {
  descriptor: ResolvedDescriptor;
  update: Uint8Array;
  pending: Uint8Array | null;
}
// "open" covers both attached and draining; whether editors are attached is
// derived from the attachment set rather than stored.
type Phase = "open" | "blocked" | "closed";
// One grant refresh per rejection. "fetching" while the request is in flight,
// "spent" once it was used, back to "idle" when the transport comes up again,
// so a renewed grant that is rejected in turn blocks instead of looping.
type Renewal = "idle" | "fetching" | "spent";
const stores = new WeakMap<CableConsumer, DocumentSessionStore>();

/** One scope per consumer. Different consumers never adopt each other's work. */
export class DocumentSessionStore extends EventTarget {
  static for(consumer: CableConsumer): DocumentSessionStore {
    let store = stores.get(consumer);
    if (!store) stores.set(consumer, store = new DocumentSessionStore(consumer));
    return store;
  }
  #sessions = new Map<string, DocumentSession>();
  #suspended = false;
  constructor(readonly consumer: CableConsumer) { super(); }
  get sessions(): readonly DocumentSession[] { return [...this.#sessions.values()]; }
  get suspended(): boolean { return this.#suspended; }

  acquire(input: DocumentDescriptor): DocumentAttachment {
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

  /** Stop this scope's network activity while keeping unsaved work in memory. */
  suspend(): void {
    this.#suspended = true;
    for (const session of this.sessions) session.provider?.disconnect();
  }
  resume(): void {
    this.#suspended = false;
    for (const session of this.sessions) session.connect();
  }
  /** @internal */
  changed(session: DocumentSession): void {
    session.dispatchEvent(new Event("change"));
    this.dispatchEvent(new CustomEvent("change", { detail: session }));
  }
}

export class DocumentAttachment {
  #controller = new AbortController();
  #released = false;
  constructor(readonly session: DocumentSession) {}
  get signal(): AbortSignal { return this.#controller.signal; }
  setPresence(state: Record<string, unknown> | null): void {
    if (!this.#released) this.session.setPresence(this, state);
  }
  /** Editor cleanup runs synchronously before the final pending-work check. */
  release(): void {
    if (this.#released) return;
    this.#released = true;
    this.#controller.abort();
    this.session.release(this);
  }
}

export class DocumentSession extends EventTarget {
  readonly doc = new Y.Doc();
  #phase: Phase = "open";
  #renewal: Renewal = "idle";
  #provider: ActionCableProvider | undefined;
  #attachments = new Set<DocumentAttachment>();
  #presenceOwner: DocumentAttachment | undefined;
  // The grant currently in use. Starts as the descriptor's and changes only
  // through a successful refresh; the descriptor itself never changes.
  #grant: string;
  // Set while blocked: the work the provider held, kept for retry() or export.
  #recovery: DocumentRecovery | undefined;
  #error: unknown;
  #waiting = false; // an acknowledgment wait is in progress
  #scheduled = false; // a settle check is queued
  #resolveSynced!: () => void;
  readonly whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });

  /** Use DocumentSessionStore.acquire to create and own sessions. */
  constructor(
    readonly store: DocumentSessionStore,
    readonly descriptor: ResolvedDescriptor,
    private readonly remove: () => void,
  ) {
    super();
    this.#grant = descriptor.grant;
    this.doc.on("update", this.#schedule);
  }
  get provider(): ActionCableProvider | undefined { return this.#provider; }
  get error(): unknown { return this.#error; }
  get attachmentCount(): number { return this.#attachments.size; }
  get hasPending(): boolean {
    if (this.#provider) return this.#provider.hasPending;
    return !!this.#recovery?.pending;
  }
  get state(): DocumentSessionState {
    if (this.#phase !== "open") return this.#phase;
    return this.#attachments.size ? "attached" : "draining";
  }

  /** @internal */
  attach(): DocumentAttachment {
    if (this.#phase === "closed") throw new Error("Document session is closed");
    const attachment = new DocumentAttachment(this);
    this.#attachments.add(attachment);
    this.connect();
    this.store.changed(this);
    return attachment;
  }
  /** @internal */
  connect(): void {
    if (this.#phase !== "open") return;
    try {
      // The provider exists even while suspended so edits queue as pending;
      // only the subscription waits for resume().
      this.#provider ??= this.#createProvider();
      if (!this.store.suspended) this.#provider.connect();
    } catch (error) {
      this.#block(error);
    }
  }
  /** @internal */
  release(attachment: DocumentAttachment): void {
    this.#attachments.delete(attachment);
    if (this.#presenceOwner === attachment || !this.#attachments.size) {
      this.#presenceOwner = undefined;
      this.#provider?.awareness.setLocalState(null);
    }
    this.#settle();
  }
  /** @internal */
  setPresence(attachment: DocumentAttachment, state: Record<string, unknown> | null): void {
    if (this.#phase !== "open" || !this.#attachments.has(attachment)) return;
    if (state) this.#presenceOwner = attachment;
    if (this.#presenceOwner === attachment) {
      this.#provider?.awareness.setLocalState(state);
      if (!state) this.#presenceOwner = undefined;
    }
  }

  /** A defensive copy for application recovery/export; never put it in cached HTML. */
  exportRecovery(): DocumentRecovery {
    return {
      descriptor: this.descriptor,
      update: Y.encodeStateAsUpdate(this.doc),
      pending: this.#provider?.pendingUpdate ?? this.#recovery?.pending?.slice() ?? null,
    };
  }
  /** Retry with this session's current grant: the original one, or the last one a refresh returned. */
  retry(): void {
    if (this.#phase !== "blocked") return;
    this.#phase = "open";
    this.#error = undefined;
    this.#renewal = "idle";
    this.connect();
    this.#settle();
  }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void {
    if (this.#phase === "closed") return;
    this.#phase = "closed";
    for (const attachment of this.#attachments) attachment.release();
    this.#dispose();
  }

  #createProvider(): ActionCableProvider {
    const provider = new ActionCableProvider(this.doc, this.store.consumer, this.descriptor.channel, {
      grant: this.#grant,
      name: this.descriptor.name,
      // Ack sequence numbers belong to this provider lifetime, not a record.
      session_id: uuidv4(),
    }, {
      onError: (error, context) => {
        if (this.#provider !== provider) return;
        if (context === "rejected") this.#rejected(provider, error);
        else { this.#error = error; this.store.changed(this); }
      },
    });
    provider.awareness.setLocalState(null);
    if (this.#recovery?.pending) provider.restorePendingUpdate(this.#recovery.pending);
    this.#recovery = undefined;
    provider.onStatusChange(({ status }) => {
      const up = status === "connected" || status === "synced";
      if (up && this.#renewal === "spent") this.#renewal = "idle";
      this.store.changed(this);
    });
    void provider.whenSynced.then(() => {
      if (this.#provider === provider && this.#phase === "open") this.#resolveSynced();
    });
    return provider;
  }

  // The server refused the subscription. With a refresh URL and no renewal
  // since the transport last came up, ask for a new grant and resubscribe
  // with it. Otherwise, or if that fails, block.
  #rejected(provider: ActionCableProvider, error: unknown): void {
    const refresh = this.descriptor.refresh;
    if (!refresh || this.#renewal !== "idle") { this.#block(error); return; }
    this.#renewal = "fetching";
    void this.#renew(provider, refresh);
  }
  async #renew(provider: ActionCableProvider, refresh: string): Promise<void> {
    let grant: string;
    try {
      grant = await fetchGrant(refresh);
    } catch (error) {
      this.#renewal = "spent";
      if (this.#provider === provider) this.#block(error);
      return;
    }
    this.#renewal = "spent";
    // The session may have moved on during the fetch: blocked, discarded, or retried with a new provider.
    if (this.#provider !== provider || this.#phase !== "open") return;
    this.#grant = grant;
    provider.renew({ grant });
    this.store.changed(this);
  }

  #block(error: unknown): void {
    if (this.#phase !== "open") return;
    this.#phase = "blocked";
    this.#error = error;
    // Teardown can flush a final editor update. Capture only after it finishes.
    for (const attachment of this.#attachments) attachment.release();
    this.#recovery = this.exportRecovery();
    this.#provider?.destroy();
    this.#provider = undefined;
    this.#waiting = false;
    this.store.changed(this);
  }
  #schedule = (): void => {
    if (this.#scheduled) return;
    this.#scheduled = true;
    queueMicrotask(() => { this.#scheduled = false; this.#settle(); });
  };
  // Close when nothing needs the session any more, or wait for the next
  // acknowledgment and check again.
  #settle(): void {
    if (this.#phase === "closed") return;
    if (this.#phase === "open" && !this.#attachments.size && !this.hasPending) {
      this.#phase = "closed";
      this.#dispose();
      return;
    }
    const provider = this.#provider;
    if (this.#phase === "open" && provider?.hasPending && !this.#waiting) {
      this.#waiting = true;
      void provider.whenAcknowledged.then(() => {
        if (this.#provider !== provider) return;
        this.#waiting = false;
        this.#settle(); // Recheck both attachments and edits added after the ack.
      });
    }
    this.store.changed(this);
  }
  #dispose(): void {
    this.remove();
    this.#provider?.destroy();
    this.#provider = undefined;
    this.#recovery = undefined;
    this.doc.off("update", this.#schedule);
    this.doc.destroy();
    this.store.changed(this);
  }
}

/** Ask the application for a new grant. Resolves to the grant or throws. */
async function fetchGrant(url: string): Promise<string> {
  const response = await fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`grant refresh failed: ${response.status}`);
  const body: unknown = await response.json();
  const grant = (body as { grant?: unknown } | null)?.grant;
  if (typeof grant !== "string" || !grant) throw new Error("grant refresh returned no grant");
  return grant;
}
