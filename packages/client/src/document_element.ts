// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page, and detaches when Turbo caches the page, the element leaves the
// DOM, or its grant/name/channel attributes change. The session, not the
// element, owns the document and any unacknowledged edits, so nothing is lost
// when the element goes away.
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

// Where the application's own inert value is parked while the element holds it inert.
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

type ErrorDetail = { error: unknown; session?: DocumentSession };

// Why an attempt cannot continue. Recorded when it happens, because the
// session may be retried before settle reads it.
type Ending =
  | { reason: "failed"; error: unknown } // the consumer or acquire failed
  | { reason: "blocked"; session: DocumentSession; error: unknown }
  | { reason: "discarded" }; // the session is gone; a fresh one can be acquired

function endingOf(session: DocumentSession): Ending {
  return session.state === "blocked" ? { reason: "blocked", session, error: session.error } : { reason: "discarded" };
}

// A document not to retry yet. One stalled on a blocked session waits for
// that session to be retried; otherwise the next page render retries it.
type Stall = { key: string; session?: DocumentSession; unwatch?: () => void };

// One try at binding one document. Async steps only record their results here
// and request a settle. A result for an abandoned attempt is simply never read.
type BindAttempt = {
  key: string;
  descriptor: DocumentDescriptor;
  consumer?: CableConsumer;
  lease?: DocumentLease;
  synced?: boolean;
  announced?: boolean;
  ended?: Ending;
};

// The element binds when it is in the page, the Turbo adapter says the page is
// live, and it has a descriptor. Abandoning an attempt is immediate: Turbo
// snapshots the page right after deactivation, and a retarget must stop
// editing the old document at once. Starting and advancing an attempt, and
// every async result, go through #settle, which runs after the current call
// stack and compares what should be bound with what is.
export class YrbyDocumentElement extends Base {
  /** Set before adding elements to use another consumer, such as AnyCable's. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  // refresh is read at acquisition and is not part of the document's
  // identity, so changing it does not rebind the editor.
  static observedAttributes = ["grant", "name", "channel"];

  #live = false; // the adapter's latest word: live page, or cached snapshot
  #attempt: BindAttempt | undefined;
  // The document not to retry yet, if any. An attribute change or
  // re-insertion always clears it.
  #stall: Stall | undefined;
  #unregister: (() => void) | undefined;
  #settleQueued = false;
  // Resolves when the current attempt first syncs. Abandoning the attempt replaces it.
  #firstSync = deferred();

  get session(): DocumentSession | undefined {
    // A lease aborted by its session is gone at once, before settle catches up.
    const lease = this.#attempt?.lease;
    return lease && !lease.signal.aborted ? lease.session : undefined;
  }
  get doc(): DocumentSession["doc"] | undefined { return this.session?.doc; }
  get provider(): DocumentSession["provider"] | undefined { return this.session?.provider; }
  /** Resolves after the current attempt's first sync; never for an abandoned attempt. */
  get whenSynced(): Promise<void> { return this.#firstSync.promise; }

  connectedCallback(): void {
    this.#clearStall();
    // A same-turn move keeps its attempt, and a live editor must not flicker inert.
    if (!this.#attempt) this.#holdInert();
    this.#unregister ??= registerDocumentMount(this);
    this.#requestSettle();
  }
  // Same-turn moves keep their binding: settle checks isConnected afterwards.
  disconnectedCallback(): void { this.#requestSettle(); }
  attributeChangedCallback(_name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue) return;
    this.#clearStall();
    this.#abandon();
    this.#requestSettle();
  }

  /** @internal Called by the Turbo adapter when the page is live. A new render retries a failed load. */
  activate(): void {
    this.#live = true;
    if (!this.#stall?.session) this.#clearStall();
    this.#requestSettle();
  }
  /** @internal Called by the Turbo adapter when the page is cached or previewed. */
  deactivate(): void {
    this.#live = false;
    this.#abandon();
  }
  /** Release the editor lease. Unsaved work remains owned by its session. */
  destroy(): void {
    // Forget the adapter's verdict; registering on the next connection gets a fresh one.
    this.#live = false;
    // Cleared before the call, which can re-enter through a replacement registration.
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
    this.#clearStall();
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
    // undefined: nothing should be bound. The page is cached, or the
    // attributes do not name a document yet.
    const key = this.#live && descriptor.grant && descriptor.name ? documentKey(descriptor) : undefined;
    if (this.#stall?.session && this.#stall.session.state !== "blocked") this.#clearStall();
    const attempt = this.#attempt;
    if (attempt && attempt.key !== key) {
      // Defensive: every change to these facts already abandons the attempt.
      this.#abandon();
      this.#requestSettle();
      return;
    }
    if (key === undefined || key === this.#stall?.key) return;

    // Advance one step: start, acquire once the consumer loads, announce once
    // synced. An ended attempt stalls or starts over instead.
    if (!attempt) this.#start(key, descriptor);
    else if (attempt.ended) this.#end(attempt.ended);
    else if (attempt.consumer && !attempt.lease) this.#acquire(attempt, attempt.consumer);
    else if (attempt.synced && !attempt.announced) this.#announce(attempt);
  }

  #start(key: string, descriptor: DocumentDescriptor): void {
    const attempt: BindAttempt = { key, descriptor };
    this.#attempt = attempt;
    Promise.resolve(YrbyDocumentElement.consumer ?? defaultConsumer()).then(
      consumer => { attempt.consumer = consumer; },
      error => { attempt.ended = { reason: "failed", error }; },
    ).then(() => this.#requestSettle());
  }
  #acquire(attempt: BindAttempt, consumer: CableConsumer): void {
    let lease: DocumentLease;
    try {
      lease = DocumentSessionStore.for(consumer).acquire(attempt.descriptor);
    } catch (error) {
      this.#end({ reason: "failed", error });
      return;
    }
    attempt.lease = lease;
    const { session } = lease;
    // A blocked session keeps new leases for retry(), and its first sync may
    // be long past. An editor must not bind to it.
    if (session.state === "blocked") {
      attempt.ended = endingOf(session);
      this.#requestSettle();
      return;
    }
    // The lease aborts when its session blocks or is discarded.
    lease.signal.addEventListener("abort", () => {
      attempt.ended ??= endingOf(session);
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
  #end(ending: Ending): void {
    const key = this.#attempt?.key;
    this.#abandon();
    if (ending.reason === "discarded") {
      this.#requestSettle(); // start over with a fresh session
      return;
    }
    if (key !== undefined) this.#stall = this.#stallOn(key, ending);
    const detail: ErrorDetail = ending.reason === "blocked"
      ? { error: ending.error, session: ending.session }
      : { error: ending.error };
    this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail }));
  }
  // A blocked session is watched, so the element binds again once it is retried or discarded.
  #stallOn(key: string, ending: Ending): Stall {
    if (ending.reason !== "blocked") return { key };
    const { session } = ending;
    const onChange = (event: Event) => {
      if ((event as CustomEvent).detail === session) this.#requestSettle();
    };
    session.store.addEventListener("change", onChange);
    return { key, session, unwatch: () => session.store.removeEventListener("change", onChange) };
  }
  #clearStall(): void {
    this.#stall?.unwatch?.();
    this.#stall = undefined;
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
  // Inert until synced, so nobody types into a document that is not live.
  // The application's own inert value is parked in an attribute, which a
  // Turbo cache clone carries along, and put back on readiness.
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
