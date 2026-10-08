// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page. It detaches when Turbo caches the page, when the element leaves
// the DOM, or when its grant/name/channel attributes change. The session holds
// the document and any unacknowledged edits, so they outlive the element.
import { type CableConsumer } from "./actioncable_provider.js";
import {
  DocumentSessionStore,
  documentKey,
  type DocumentDescriptor,
  type DocumentLease,
  type DocumentSession,
} from "./document_session.js";
import { registerDocumentMount } from "./turbo_adapter.js";

// Lets tests and SSR import this module where HTMLElement is undefined.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;

// Holds the application's own inert value while the element forces inert on.
const INERT_ATTRIBUTE = "data-yrby-inert";

/** A consumer, a promise of one, or a function that returns either. */
export type ConsumerSource = CableConsumer | Promise<CableConsumer> | (() => CableConsumer | Promise<CableConsumer>);

let sharedConsumer: Promise<CableConsumer> | undefined;

// Loads once per page. A failed import is cleared so a later attempt can retry it.
function defaultConsumer(): Promise<CableConsumer> {
  sharedConsumer ??= import("@rails/actioncable")
    .then(actioncable => actioncable.createConsumer() as CableConsumer)
    .catch(error => { sharedConsumer = undefined; throw error; });
  return sharedConsumer;
}

let assignedConsumer: ConsumerSource | undefined;
// The last factory called and its result. Assigning a new value clears it,
// and so does a failed result, so the next attempt calls the factory again.
let factoryResult: { factory: () => unknown; consumer: Promise<CableConsumer> } | undefined;

function loadConsumer(source: ConsumerSource | null | undefined): Promise<CableConsumer> {
  if (source == null) return defaultConsumer();
  if (typeof source !== "function") return Promise.resolve(source);
  if (factoryResult?.factory === source) return factoryResult.consumer;
  let consumer: Promise<CableConsumer>;
  try {
    consumer = Promise.resolve(source());
  } catch (error) {
    return Promise.reject(error);
  }
  const entry = { factory: source, consumer };
  factoryResult = entry;
  consumer.catch(() => { if (factoryResult === entry) factoryResult = undefined; });
  return consumer;
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>(r => { resolve = r; });
  return { promise, resolve };
}

// Returns the yrby:error detail for a session that ended a lease. A block gets
// a detail, and a discard gets undefined.
function blockReport(session: DocumentSession): ErrorDetail | undefined {
  return session.state === "blocked" ? { error: session.error, session } : undefined;
}

type ErrorDetail = { error: unknown; session?: DocumentSession };

/** The `yrby:synced` event's detail, which `element.current` also returns. */
export type SyncedDetail = {
  session: DocumentSession;
  doc: DocumentSession["doc"];
  provider: DocumentSession["provider"];
  lease: DocumentLease;
  signal: AbortSignal;
};

// One try at binding one document. Async steps record their results here and
// request a settle. Results that arrive after the attempt is abandoned go
// unread.
type BindAttempt = {
  key: string;
  descriptor: DocumentDescriptor;
  consumer?: CableConsumer;
  lease?: DocumentLease;
  synced?: boolean;
  // The yrby:synced detail, set just before the event is dispatched.
  announced?: SyncedDetail;
  // Set when the attempt can't continue, with the yrby:error detail if there is one.
  ended?: { detail: ErrorDetail | undefined };
};

// The element binds when it is in the page, the Turbo adapter reports the page
// as live, and it has a descriptor. It abandons an attempt synchronously,
// because Turbo copies the page as soon as before-cache fires, and after a
// retarget the editor has to stop writing to the old document before anything
// else runs. Starting and advancing an attempt and handling every async result
// all go through #settle, which runs after the current call stack and compares
// what should be bound with what is.
export class YrbyDocumentElement extends Base {
  /**
   * Set before adding elements to use another consumer, such as AnyCable's.
   * It takes a consumer, a promise of one, or a function that returns either.
   * The element calls the function when it first needs a consumer and reuses
   * the result. If the function throws or its promise rejects, the next
   * attempt calls it again. Assigning a different value replaces the reused
   * result. When unset, elements share an `@rails/actioncable` consumer.
   */
  static get consumer(): ConsumerSource | undefined { return assignedConsumer; }
  static set consumer(value: ConsumerSource | undefined) {
    if (value === assignedConsumer) return;
    assignedConsumer = value;
    factoryResult = undefined;
  }
  // refresh is read when the session is acquired and isn't part of the
  // document's identity, so changing it doesn't rebind the editor.
  static observedAttributes = ["grant", "name", "channel"];

  #live = false; // false while Turbo is showing a cached copy of the page
  #attempt: BindAttempt | undefined;
  // Key of the document whose session blocked or failed. The element won't retry
  // it until the page renders again, the attributes change, or the element is
  // re-inserted.
  #stalledKey: string | undefined;
  #unregister: (() => void) | undefined;
  #settleQueued = false;
  // Resolves when the current attempt first syncs. Abandoning the attempt replaces it.
  #firstSync = deferred();

  get session(): DocumentSession | undefined {
    // Treat a lease its session aborted as gone, even before settle runs.
    const lease = this.#attempt?.lease;
    return lease && !lease.signal.aborted ? lease.session : undefined;
  }
  get doc(): DocumentSession["doc"] | undefined { return this.session?.doc; }
  get provider(): DocumentSession["provider"] | undefined { return this.session?.provider; }
  /** Resolves after the current attempt's first sync. If the attempt is abandoned, its promise never resolves. */
  get whenSynced(): Promise<void> { return this.#firstSync.promise; }
  /**
   * The `yrby:synced` detail of the session the element is bound to. It is
   * undefined before the first sync, while the element retargets or the page
   * is cached, while the document is stalled, and as soon as the lease aborts.
   * Reading it never creates anything.
   */
  get current(): SyncedDetail | undefined {
    const detail = this.#attempt?.announced;
    return detail && !detail.signal.aborted ? detail : undefined;
  }

  connectedCallback(): void {
    this.#stalledKey = undefined;
    // A same-turn move keeps its attempt, so don't make a live editor inert.
    if (!this.#attempt) this.#holdInert();
    this.#unregister ??= registerDocumentMount(this);
    this.#requestSettle();
  }
  // Same-turn moves keep their binding, because settle checks isConnected afterwards.
  disconnectedCallback(): void { this.#requestSettle(); }
  attributeChangedCallback(_name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue) return;
    this.#stalledKey = undefined;
    this.#abandon();
    this.#requestSettle();
  }

  /** @internal Called by the Turbo adapter when the page is live. A new render also retries a stalled document. */
  activate(): void {
    this.#live = true;
    this.#stalledKey = undefined;
    this.#requestSettle();
  }
  /** @internal Called by the Turbo adapter when the page is cached or previewed. */
  deactivate(): void {
    this.#live = false;
    this.#abandon();
  }
  /**
   * Acquires the document again after its session blocked or was discarded.
   * It doesn't change whether the page is live, so a cached page binds when
   * Turbo shows it again. It does nothing while the element is bound to, or
   * still acquiring, a session whose lease hasn't aborted.
   *
   * It is safe to call from a lease abort handler, or right after
   * `session.discard()` in the same call stack. The element drops the ended
   * attempt immediately, so the settle that would have stalled it acquires
   * instead. A discarded session is gone from the store, so that acquisition
   * creates a new session with a new `Y.Doc`. A session that is still blocked
   * is reported again with `yrby:error`.
   */
  retry(): void {
    const attempt = this.#attempt;
    if (attempt && !attempt.ended && !attempt.lease?.signal.aborted) return;
    this.#stalledKey = undefined;
    this.#abandon();
    this.#requestSettle();
  }
  /** Releases the editor lease. The session keeps any unsaved work. */
  destroy(): void {
    // Reset the adapter's last report. The next connection registers again and gets a new one.
    this.#live = false;
    // Clear it before the call, since the call can re-enter through a replacement registration.
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
    this.#abandon();
  }

  #requestSettle(): void {
    if (this.#settleQueued) return;
    this.#settleQueued = true;
    queueMicrotask(() => this.#settle());
  }
  #settle(): void {
    this.#settleQueued = false;
    if (!this.isConnected) { this.destroy(); return; }
    const descriptor = this.#descriptor();
    // key is undefined when nothing should be bound, because the page is cached
    // or the attributes don't name a document yet.
    const key = this.#live && descriptor.grant && descriptor.name ? documentKey(descriptor) : undefined;
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      // Should not happen, since every change to these facts already abandons the attempt.
      this.#abandon();
      this.#requestSettle();
      return;
    }
    if (key === undefined || key === this.#stalledKey) return;

    // Take the next step. An attempt starts, acquires a lease once the consumer
    // loads, and announces once synced. If the attempt has ended, stall.
    if (!attempt) this.#start(key, descriptor);
    else if (attempt.ended) this.#stall(attempt.ended.detail);
    else if (attempt.consumer && !attempt.lease) this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced) this.#announce(attempt);
  }

  #start(key: string, descriptor: DocumentDescriptor): void {
    const attempt: BindAttempt = { key, descriptor };
    this.#attempt = attempt;
    loadConsumer(YrbyDocumentElement.consumer).then(
      consumer => { attempt.consumer = consumer; },
      error => { attempt.ended = { detail: { error } }; },
    ).then(() => this.#requestSettle());
  }
  #acquire(attempt: BindAttempt, consumer: CableConsumer): void {
    let lease: DocumentLease;
    try {
      lease = DocumentSessionStore.for(consumer).acquire(attempt.descriptor);
    } catch (error) {
      this.#stall({ error });
      return;
    }
    attempt.lease = lease;
    const { session } = lease;
    // A blocked session keeps new leases for retry(), and its first sync may
    // be long past, so an editor must not bind to it.
    const blocked = blockReport(session);
    if (blocked) {
      attempt.ended = { detail: blocked };
      this.#requestSettle();
      return;
    }
    // The lease aborts when its session blocks or is discarded. Read the
    // reason now, before anything retries the session.
    lease.signal.addEventListener("abort", () => {
      attempt.ended ??= { detail: blockReport(session) };
      this.#requestSettle();
    }, { once: true });
    void session.whenSynced.then(() => {
      attempt.synced = true;
      this.#requestSettle();
    });
  }
  #announce(attempt: BindAttempt): void {
    const lease = attempt.lease!;
    const { session } = lease;
    const detail: SyncedDetail = { session, doc: session.doc, provider: session.provider, lease, signal: lease.signal };
    attempt.announced = detail;
    this.#restoreInert();
    this.#firstSync.resolve();
    this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true, detail }));
  }
  #stall(detail: ErrorDetail | undefined): void {
    this.#stalledKey = this.#attempt?.key;
    this.#abandon();
    if (detail) this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail }));
  }
  // Ends the current attempt. Releasing the lease runs editor cleanup, which
  // may change attributes or move the element, and those changes only request
  // a settle.
  #abandon(): void {
    const attempt = this.#attempt;
    if (!attempt) return;
    this.#attempt = undefined;
    this.#firstSync = deferred();
    this.#holdInert();
    attempt.lease?.release();
  }

  #descriptor(): DocumentDescriptor {
    return {
      channel: this.getAttribute("channel") || undefined,
      grant: this.getAttribute("grant") || "",
      name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || undefined,
    };
  }
  // Stay inert until synced so nobody types into a document that isn't live yet.
  // The application's own inert value goes in an attribute, which survives a
  // Turbo cache clone, and is restored when the element is ready.
  #holdInert(): void {
    if (!this.hasAttribute(INERT_ATTRIBUTE)) this.setAttribute(INERT_ATTRIBUTE, String(this.inert));
    this.inert = true;
  }
  #restoreInert(): void {
    const saved = this.getAttribute(INERT_ATTRIBUTE);
    if (saved === null) return;
    this.inert = saved === "true";
    this.removeAttribute(INERT_ATTRIBUTE);
  }
}

if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
