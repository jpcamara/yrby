// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page, and detaches when Turbo caches the page, the element leaves the
// DOM, or its grant/name/channel attributes change. The session, not the
// element, owns the document and any unacknowledged edits, so nothing is lost
// when the element goes away.
import { type CableConsumer } from "./actioncable_provider.js";
import { DocumentSessionStore, type DocumentDescriptor, type DocumentLease } from "./document_session.js";
import { registerDocumentMount } from "./turbo_adapter.js";

// Importable outside a browser (tests, SSR) where HTMLElement is undefined.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;
let sharedConsumer: Promise<CableConsumer> | undefined;
function defaultConsumer(): Promise<CableConsumer> {
  return sharedConsumer ??= import("@rails/actioncable")
    .then(ac => ac.createConsumer() as CableConsumer)
    .catch(error => { sharedConsumer = undefined; throw error; });
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>(r => { resolve = r; });
  return { promise, resolve };
}

// One try at binding one document. Async steps only record their results here
// and request a settle. A result for an abandoned attempt is simply never read.
type Attempt = {
  key: string;
  descriptor: DocumentDescriptor;
  consumer?: CableConsumer;
  lease?: DocumentLease;
  synced?: boolean;
  announced?: boolean;
  // Set when the attempt cannot continue, with the yrby:error detail to report, if any.
  ended?: { report?: ErrorReport };
};
type ErrorReport = { error: unknown; session?: DocumentLease["session"] };

// The element binds when it is in the page, the Turbo adapter says the page is
// live, and it has a descriptor. Letting go is immediate: Turbo snapshots the
// page right after deactivation, and a retarget must stop editing the old
// document at once. Taking hold, and every async result, goes through #settle,
// which runs after the current call stack and compares what should be bound
// with what is.
export class YrbyDocumentElement extends Base {
  /** Set before adding elements to use another consumer, such as AnyCable's. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  static observedAttributes = ["grant", "name", "channel", "refresh"];
  #live = false; // the adapter's latest word: live page, or cached snapshot
  #attempt: Attempt | undefined;
  // A document whose session blocked or failed. Not retried until the page
  // renders again, the attributes change, or the element is re-inserted.
  #stalled: string | undefined;
  #unregister: (() => void) | undefined;
  #settleQueued = false;
  // Settles when the current attempt first syncs. Abandoning the attempt replaces it.
  #readiness = deferred();
  get session() { return this.#attempt?.lease?.session; }
  get doc() { return this.session?.doc; }
  get provider() { return this.session?.provider; }
  /** Resolves after the current lease's first catch-up; never for an abandoned one. */
  get whenSynced(): Promise<void> { return this.#readiness.promise; }

  connectedCallback(): void {
    this.#stalled = undefined;
    if (!this.#attempt) this.#holdInert();
    this.#unregister ??= registerDocumentMount(this);
    this.#requestSettle();
  }
  // Same-turn moves keep their binding: settle checks isConnected afterwards.
  disconnectedCallback(): void { this.#requestSettle(); }
  attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue) return;
    // The refresh URL is read when the session is acquired and is not part of
    // its identity, so changing it does not rebind the editor.
    if (name === "refresh") return;
    this.#stalled = undefined;
    this.#letGo();
    this.#requestSettle();
  }

  /** @internal Called by the Turbo adapter. A new render also retries a stalled document. */
  activate(): void {
    this.#live = true;
    this.#stalled = undefined;
    this.#requestSettle();
  }
  /** @internal */
  deactivate(): void {
    this.#live = false;
    this.#letGo();
  }
  /** Release the editor lease. Unsaved work remains owned by its session. */
  destroy(): void {
    // Registering again on the next connection asks the adapter for a fresh verdict.
    this.#live = false;
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
    this.#letGo();
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
    const key = this.#live ? JSON.stringify([descriptor.channel, descriptor.grant, descriptor.name]) : undefined;
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      // Editor cleanup can change the facts; decide again once it has finished.
      this.#letGo();
      this.#requestSettle();
      return;
    }
    if (key === undefined || key === this.#stalled) return;

    if (!attempt) this.#start(key, descriptor);
    else if (attempt.ended) this.#stall(attempt.ended.report);
    else if (attempt.consumer && !attempt.lease) this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced) this.#announce(attempt);
  }

  #start(key: string, descriptor: DocumentDescriptor): void {
    const attempt: Attempt = { key, descriptor };
    this.#attempt = attempt;
    Promise.resolve(YrbyDocumentElement.consumer ?? defaultConsumer()).then(
      consumer => { attempt.consumer = consumer; },
      error => { attempt.ended = { report: { error } }; },
    ).then(() => this.#requestSettle());
  }
  #acquire(attempt: Attempt, consumer: CableConsumer): void {
    let lease: DocumentLease;
    try {
      lease = DocumentSessionStore.for(consumer).acquire(attempt.descriptor);
    } catch (error) {
      this.#stall({ error });
      return;
    }
    attempt.lease = lease;
    // Blocked or discarded. Only a block is reported, and the session's state
    // is read now, before anything can retry it.
    lease.signal.addEventListener("abort", () => {
      const { session } = lease;
      attempt.ended ??= { report: session.state === "blocked" ? { error: session.error, session } : undefined };
      this.#requestSettle();
    }, { once: true });
    void lease.session.whenSynced.then(() => { attempt.synced = true; this.#requestSettle(); });
  }
  #announce(attempt: Attempt): void {
    attempt.announced = true;
    const lease = attempt.lease!, { session } = lease;
    this.#restoreInert();
    this.#readiness.resolve();
    this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true,
      detail: { session, doc: session.doc, provider: session.provider, lease, signal: lease.signal } }));
  }
  // Give up on this document until the page renders again, the attributes
  // change, or the element is re-inserted.
  #stall(report: ErrorReport | undefined): void {
    this.#stalled = this.#attempt?.key;
    this.#letGo();
    if (report) this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: report }));
  }
  // End the current attempt. Releasing the lease runs editor cleanup, which
  // may change attributes or move the element; those only request a settle.
  #letGo(): void {
    const attempt = this.#attempt;
    if (!attempt) return;
    this.#attempt = undefined;
    this.#readiness = deferred();
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
  // Inert until synced, so nobody types into a document that is not live.
  // The application's own inert value is parked in an attribute, which a
  // Turbo cache clone carries along, and put back on readiness.
  #holdInert(): void {
    if (this.getAttribute("data-yrby-inert") === null) this.setAttribute("data-yrby-inert", String(this.inert));
    this.inert = true;
  }
  #restoreInert(): void {
    const saved = this.getAttribute("data-yrby-inert");
    if (saved === null) return;
    this.inert = saved === "true";
    this.removeAttribute("data-yrby-inert");
  }
}
if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
