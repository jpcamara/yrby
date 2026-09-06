// Application document ownership, independent of editors and page navigation.
import * as Y from "yjs";
import { uuidv4 } from "lib0/random";
import { ActionCableProvider, type CableConsumer } from "./actioncable_provider.js";

export interface DocumentDescriptor { channel?: string; grant: string; name: string }
export type DocumentSessionState = "attached" | "draining" | "blocked" | "closed";
export interface DocumentRecovery {
  descriptor: Readonly<Required<DocumentDescriptor>>;
  update: Uint8Array;
  pending: Uint8Array | null;
}
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
    const descriptor = Object.freeze({ channel: input.channel || "Y::DocumentChannel", grant: input.grant, name: input.name });
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
  #provider: ActionCableProvider | undefined;
  #attachments = new Set<DocumentAttachment>();
  #presenceOwner: DocumentAttachment | undefined;
  #blocked = false;
  #closed = false;
  #recovery: DocumentRecovery | undefined;
  #waiting = false;
  #scheduled = false;
  #error: unknown;
  #resolveSynced!: () => void;
  readonly whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });

  /** Use DocumentSessionStore.acquire to create and own sessions. */
  constructor(
    readonly store: DocumentSessionStore,
    readonly descriptor: Readonly<Required<DocumentDescriptor>>,
    private readonly remove: () => void,
  ) {
    super();
    this.doc.on("update", this.#schedule);
  }
  get provider(): ActionCableProvider | undefined { return this.#provider; }
  get error(): unknown { return this.#error; }
  get attachmentCount(): number { return this.#attachments.size; }
  get hasPending(): boolean { return this.#provider?.hasPending ?? !!this.#recovery?.pending; }
  get state(): DocumentSessionState {
    return this.#closed ? "closed" : this.#blocked ? "blocked" : this.#attachments.size ? "attached" : "draining";
  }

  /** @internal */
  attach(): DocumentAttachment {
    if (this.#closed) throw new Error("Document session is closed");
    const attachment = new DocumentAttachment(this);
    this.#attachments.add(attachment);
    this.connect();
    this.store.changed(this);
    return attachment;
  }
  /** @internal */
  connect(): void {
    if (this.#closed || this.#blocked || this.store.suspended) return;
    try {
      if (!this.#provider) {
        const provider = this.#provider = new ActionCableProvider(this.doc, this.store.consumer, this.descriptor.channel, {
          grant: this.descriptor.grant, name: this.descriptor.name,
          // Ack sequence numbers belong to this provider lifetime, not a record.
          session_id: uuidv4(),
        }, { onError: (error, context) => {
          if (this.#provider !== provider) return;
          if (context === "rejected") this.#block(error);
          else { this.#error = error; this.store.changed(this); }
        } });
        provider.awareness.setLocalState(null);
        if (this.#recovery?.pending) provider.restorePendingUpdate(this.#recovery.pending);
        this.#recovery = undefined;
        provider.onStatusChange(() => this.store.changed(this));
        void provider.whenSynced.then(() => {
          if (this.#provider === provider && !this.#blocked) this.#resolveSynced();
        });
      }
      this.#provider.connect();
    } catch (error) { this.#block(error); }
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
    if (this.#blocked || !this.#attachments.has(attachment)) return;
    if (state) this.#presenceOwner = attachment;
    if (this.#presenceOwner === attachment) {
      this.#provider?.awareness.setLocalState(state);
      if (!state) this.#presenceOwner = undefined;
    }
  }

  /** A defensive copy for application recovery/export; never put it in cached HTML. */
  exportRecovery(): DocumentRecovery {
    return { descriptor: this.descriptor, update: Y.encodeStateAsUpdate(this.doc),
      pending: this.#provider?.pendingUpdate ?? this.#recovery?.pending?.slice() ?? null };
  }
  /** Retry only with this session's original authorization. */
  retry(): void {
    if (!this.#blocked || this.#closed) return;
    this.#blocked = false;
    this.#error = undefined;
    this.connect();
    this.#settle();
  }
  /** Explicit application decision; ordinary detach never discards pending work. */
  discard(): void {
    if (this.#closed) return;
    this.#closed = true;
    for (const attachment of this.#attachments) attachment.release();
    this.#dispose();
  }

  #block(error: unknown): void {
    if (this.#closed || this.#blocked) return;
    this.#blocked = true;
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
  #settle(): void {
    if (this.#closed) return;
    if (!this.#blocked && !this.#attachments.size && !this.hasPending) {
      this.#closed = true;
      this.#dispose();
      return;
    }
    const provider = this.#provider;
    if (!this.#blocked && provider?.hasPending && !this.#waiting) {
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
