// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page, and detaches when Turbo caches the page, the element leaves the
// DOM, or its grant/name/channel attributes change. The session, not the
// element, owns the document and any unacknowledged edits, so nothing is lost
// when the element goes away.
import { type CableConsumer } from "./actioncable_provider.js";
import { DocumentSessionStore, type DocumentLease } from "./document_session.js";
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

// "idle" is activated but unbound; "inactive" waits for the adapter's activation.
// Async completions carry the state that started them. Leaving it invalidates them.
type Loading = { phase: "loading" };
type Syncing = { phase: "syncing"; lease: DocumentLease };
type ElementState =
  | { phase: "detached" | "inactive" | "idle" }
  | Loading | Syncing
  | { phase: "ready"; lease: DocumentLease };
type Phase = ElementState["phase"];

// Every outside request, the phases it may leave, and where it goes. A request
// from any other phase is a no-op. Loading additionally requires a connected
// element. Async completions are not listed: they check identity instead.
const attempting = ["loading", "syncing", "ready"] as const;
const live = ["idle", ...attempting] as const;
const requests = {
  connect: { from: ["detached"], to: "inactive" },
  // Turbo's adapter decides the page is live.
  activate: { from: ["inactive", "idle"], to: "loading" },
  // A queued retarget wakes only an idle element, never one Turbo deactivated for caching.
  resume: { from: ["idle"], to: "loading" },
  retarget: { from: live, to: "idle" },
  deactivate: { from: live, to: "inactive" },
  destroy: { from: ["inactive", ...live], to: "detached" },
} as const satisfies Record<string, { from: readonly Phase[]; to: "detached" | "inactive" | "idle" | "loading" }>;

export class YrbyDocumentElement extends Base {
  /** Set before adding elements to use another consumer, such as AnyCable's. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  static observedAttributes = ["grant", "name", "channel", "refresh"];
  #state: ElementState = { phase: "detached" };
  #unregister: (() => void) | undefined;
  // Settles when the current attempt first syncs. Abandoning the attempt replaces it.
  #readiness = deferred();
  get session() { return "lease" in this.#state ? this.#state.lease.session : undefined; }
  get doc() { return this.session?.doc; }
  get provider() { return this.session?.provider; }
  /** Resolves after the current lease's first catch-up; never for an abandoned one. */
  get whenSynced(): Promise<void> { return this.#readiness.promise; }

  connectedCallback(): void {
    this.#request("connect");
    this.#unregister ??= registerDocumentMount(this);
    this.#request("resume");
  }
  disconnectedCallback(): void {
    // Same-turn moves keep their binding. Async results check isConnected
    // directly while this deferred removal is still waiting to run.
    queueMicrotask(() => { if (!this.isConnected) this.destroy(); });
  }
  attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue) return;
    // The refresh URL is read when the session is acquired and is not part of
    // its identity, so changing it does not rebind the editor.
    if (name === "refresh") return;
    this.#request("retarget");
    queueMicrotask(() => this.#request("resume"));
  }

  /** @internal Called by the Turbo adapter. */
  activate(): void { this.#request("activate"); }
  /** @internal */
  deactivate(): void { this.#request("deactivate"); }
  /** Release the editor lease. Unsaved work remains owned by its session. */
  destroy(): void { this.#request("destroy"); }

  #request(name: keyof typeof requests): void {
    const { from, to } = requests[name];
    if (!(from as readonly Phase[]).includes(this.#state.phase)) return;
    if (to === "loading" && !this.isConnected) return;
    this.#setState({ phase: to });
  }
  #acquired(from: Loading, lease: DocumentLease): void {
    if (this.#state !== from || !this.isConnected) { lease.release(); return; }
    this.#setState({ phase: "syncing", lease });
  }
  #failed(from: Loading, error: unknown): void {
    if (this.#state !== from || !this.isConnected) return;
    this.#setState({ phase: "idle" });
    this.#error(error);
  }
  #synced(from: Syncing): void {
    if (this.#state === from && this.isConnected) this.#setState({ phase: "ready", lease: from.lease });
  }
  #released(lease: DocumentLease): void {
    const current = this.#state;
    if (!("lease" in current) || current.lease !== lease) return;
    this.#setState({ phase: "idle" });
    if (lease.session.state === "blocked") this.#error(lease.session.error, lease.session);
  }

  #setState(next: ElementState): void {
    const previous = this.#state;
    this.#state = next;
    // loading -> syncing -> ready is one attempt moving forward with one lease.
    // Leaving an attempt any other way abandons it.
    const advancing = (previous.phase === "loading" && next.phase === "syncing") ||
      (previous.phase === "syncing" && next.phase === "ready");
    if (!advancing && (attempting as readonly Phase[]).includes(previous.phase)) this.#readiness = deferred();

    // Settle the element before the old lease's editor cleanup runs below.
    if (next.phase !== "ready") this.#holdInert();
    if (next.phase === "detached") this.#unregisterMount();
    if ("lease" in previous && !advancing) previous.lease.release();
    // That cleanup can synchronously retarget or remount this element.
    if (this.#state !== next) return;

    if (next.phase === "loading") void this.#load(next);
    else if (next.phase === "syncing") this.#watchLease(next);
    else if (next.phase === "ready") this.#announceReady(next.lease);
  }

  async #load(from: Loading): Promise<void> {
    const descriptor = {
      channel: this.getAttribute("channel") || undefined,
      grant: this.getAttribute("grant") || "",
      name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || undefined,
    };
    try {
      const consumer = await (YrbyDocumentElement.consumer ?? defaultConsumer());
      if (this.#state !== from || !this.isConnected) return;
      const lease = DocumentSessionStore.for(consumer).acquire(descriptor);
      this.#acquired(from, lease);
    } catch (error) {
      this.#failed(from, error);
    }
  }
  #watchLease(from: Syncing): void {
    const { lease } = from, { session } = lease;
    // A store listener may have blocked or discarded it inside acquire().
    if (lease.signal.aborted) { this.#released(lease); return; }
    lease.signal.addEventListener("abort", () => this.#released(lease), { once: true });
    if (session.state === "blocked") { lease.release(); return; }
    void session.whenSynced.then(() => this.#synced(from));
  }
  #announceReady(lease: DocumentLease): void {
    const { session } = lease;
    this.#restoreInert();
    this.#readiness.resolve();
    this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true,
      detail: { session, doc: session.doc, provider: session.provider, lease, signal: lease.signal } }));
  }
  #unregisterMount(): void {
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
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
  #error(error: unknown, session?: DocumentLease["session"]): void {
    this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: { error, session } }));
  }
}
if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
