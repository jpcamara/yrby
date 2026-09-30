// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page. It detaches when Turbo caches the page, when the element leaves
// the DOM, or when its grant/name/channel attributes change. The session owns
// the document and any unacknowledged edits, so they survive the element
// going away.
import { type CableConsumer } from "./actioncable_provider.js";
import {
  DocumentSessionStore,
  documentKey,
  type DocumentDescriptor,
  type DocumentLease,
  type DocumentSession,
} from "./document_session.js";
import { registerDocumentMount } from "./turbo_adapter.js";

// Importable outside a browser (tests, SSR) where HTMLElement is undefined.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;

// Saves the application's own inert value while the element forces inert on.
const INERT_ATTRIBUTE = "data-yrby-inert";

let sharedConsumer: Promise<CableConsumer> | undefined;

// Loaded once per page. A failed import is forgotten so a later attempt can retry it.
function defaultConsumer(): Promise<CableConsumer> {
  sharedConsumer ??= import("@rails/actioncable")
    .then(actioncable => actioncable.createConsumer() as CableConsumer)
    .catch(error => { sharedConsumer = undefined; throw error; });
  return sharedConsumer;
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>(r => { resolve = r; });
  return { promise, resolve };
}

// The yrby:error detail for a session that ended a lease. A block is reported;
// a discard is not.
function blockReport(session: DocumentSession): ErrorDetail | undefined {
  return session.state === "blocked" ? { error: session.error, session } : undefined;
}

type ErrorDetail = { error: unknown; session?: DocumentSession };

// One try at binding one document. Async steps write their results here and
// ask for a settle. If the attempt was abandoned in the meantime, nothing
// reads the result.
type BindAttempt = {
  key: string;
  descriptor: DocumentDescriptor;
  consumer?: CableConsumer;
  lease?: DocumentLease;
  synced?: boolean;
  announced?: boolean;
  // Set when the attempt cannot continue, with the yrby:error detail, if any.
  ended?: { detail: ErrorDetail | undefined };
};

// The element binds when it is in the page, the Turbo adapter says the page is
// live, and it has a descriptor. Abandoning an attempt happens synchronously.
// Turbo copies the page as soon as before-cache fires, and after a retarget
// the editor has to stop writing to the old document before anything else
// runs. Starting an attempt, advancing it, and handling every async result
// go through #settle, which runs after the current call stack and compares
// what should be bound with what is.
export class YrbyDocumentElement extends Base {
  /** Set before adding elements to use another consumer, such as AnyCable's. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  // refresh is read at acquisition and is not part of the document's
  // identity, so changing it does not rebind the editor.
  static observedAttributes = ["grant", "name", "channel"];

  #live = false; // what the Turbo adapter last told us: the page is live, or it is a cached copy
  #attempt: BindAttempt | undefined;
  // The document whose session blocked or failed. It is not retried until the
  // page renders again, the attributes change, or the element is re-inserted.
  #stalledKey: string | undefined;
  #unregister: (() => void) | undefined;
  #settleQueued = false;
  // Resolves when the current attempt first syncs. Abandoning the attempt replaces it.
  #firstSync = deferred();

  get session(): DocumentSession | undefined {
    // A lease its session aborted is already gone, even before settle has run.
    const lease = this.#attempt?.lease;
    return lease && !lease.signal.aborted ? lease.session : undefined;
  }
  get doc(): DocumentSession["doc"] | undefined { return this.session?.doc; }
  get provider(): DocumentSession["provider"] | undefined { return this.session?.provider; }
  /** Resolves after the current attempt's first sync. An abandoned attempt's promise is left unresolved. */
  get whenSynced(): Promise<void> { return this.#firstSync.promise; }

  connectedCallback(): void {
    this.#stalledKey = undefined;
    // A same-turn move keeps its attempt, so don't flip a live editor to inert.
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
  /** Release the editor lease. Unsaved work is kept by its session. */
  destroy(): void {
    // Forget what the adapter said. Registering on the next connection gets a fresh answer.
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
    // key is undefined when nothing should be bound, either because the page
    // is cached or because the attributes do not name a document yet.
    const key = this.#live && descriptor.grant && descriptor.name ? documentKey(descriptor) : undefined;
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      // Should not happen, since every change to these facts already abandons the attempt.
      this.#abandon();
      this.#requestSettle();
      return;
    }
    if (key === undefined || key === this.#stalledKey) return;

    // Advance one step. Start, then acquire once the consumer loads, then
    // announce once synced. An ended attempt stalls.
    if (!attempt) this.#start(key, descriptor);
    else if (attempt.ended) this.#stall(attempt.ended.detail);
    else if (attempt.consumer && !attempt.lease) this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced) this.#announce(attempt);
  }

  #start(key: string, descriptor: DocumentDescriptor): void {
    const attempt: BindAttempt = { key, descriptor };
    this.#attempt = attempt;
    Promise.resolve(YrbyDocumentElement.consumer ?? defaultConsumer()).then(
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
    // be long past. An editor must not bind to it.
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
    attempt.announced = true;
    const lease = attempt.lease!;
    const { session } = lease;
    this.#restoreInert();
    this.#firstSync.resolve();
    this.dispatchEvent(new CustomEvent("yrby:synced", {
      bubbles: true,
      detail: { session, doc: session.doc, provider: session.provider, lease, signal: lease.signal },
    }));
  }
  #stall(detail: ErrorDetail | undefined): void {
    this.#stalledKey = this.#attempt?.key;
    this.#abandon();
    if (detail) this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail }));
  }
  // Ends the current attempt. Releasing the lease runs editor cleanup, which
  // may change attributes or move the element; those only request a settle.
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
  // Inert until synced, so nobody types into a document that is not live yet.
  // The application's own inert value is saved in an attribute, which
  // survives a Turbo cache clone, and put back when the element is ready.
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
