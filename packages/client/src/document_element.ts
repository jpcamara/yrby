// <yrby-document grant="..." name="..." [channel="..."] [refresh="..."]>
//
// The element attaches an editor to a document session while it is live in
// the page, and detaches when Turbo caches the page, the element leaves the
// DOM, or its grant/name/channel attributes change. The session, not the
// element, owns the document and any unacknowledged edits, so nothing is lost
// when the element goes away.
import { type CableConsumer } from "./actioncable_provider.js";
import { DocumentSessionStore, type DocumentAttachment } from "./document_session.js";
import { registerDocumentMount } from "./turbo_adapter.js";

// Importable outside a browser (tests, SSR) where HTMLElement is undefined.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;
let sharedConsumer: Promise<CableConsumer> | undefined;
function defaultConsumer(): Promise<CableConsumer> {
  return sharedConsumer ??= import("@rails/actioncable")
    .then(ac => ac.createConsumer() as CableConsumer)
    .catch(error => { sharedConsumer = undefined; throw error; });
}

export class YrbyDocumentElement extends Base {
  /** Set before adding elements to use another consumer, such as AnyCable's. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  static observedAttributes = ["grant", "name", "channel", "refresh"];
  #attachment: DocumentAttachment | undefined;
  #attaching = false; // waiting for the consumer
  #inDom = false;
  #active = false; // the Turbo adapter says: bind (not a cached preview, connected)
  #generation = 0; // bumped on every release so stale async work stands down
  #unregister: (() => void) | undefined;
  #resolveSynced!: () => void;
  #whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });
  get session() { return this.#attachment?.session; }
  get doc() { return this.session?.doc; }
  get provider() { return this.session?.provider; }
  /** Resolves after the current attachment's first catch-up; never for an abandoned one. */
  get whenSynced(): Promise<void> { return this.#whenSynced; }

  connectedCallback(): void {
    this.#inDom = true;
    this.#unregister ??= registerDocumentMount(this);
  }
  disconnectedCallback(): void {
    this.#inDom = false;
    // Same-turn moves keep their binding, queue, undo history, and presence.
    queueMicrotask(() => { if (!this.#inDom) this.destroy(); });
  }
  attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue || !this.#inDom) return;
    // The refresh URL is read when the session is acquired and is not part of
    // its identity, so changing it does not rebind the editor.
    if (name === "refresh") return;
    this.#release();
    const generation = this.#generation;
    queueMicrotask(() => { if (generation === this.#generation) void this.#attach(); });
  }

  /** @internal Called by the Turbo adapter. */
  activate(): void { this.#active = true; void this.#attach(); }
  /** @internal */
  deactivate(): void { this.#active = false; this.#release(); }
  /** Release the editor attachment. Unsaved work remains owned by its session. */
  destroy(): void {
    this.#inDom = false;
    this.deactivate();
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
  }

  async #attach(): Promise<void> {
    if (!this.#active || this.#attaching || this.#attachment) return;
    this.#attaching = true;
    this.#holdInert();
    const generation = this.#generation;
    const descriptor = {
      channel: this.getAttribute("channel") || undefined,
      grant: this.getAttribute("grant") || "",
      name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || undefined,
    };
    try {
      const consumer = await (YrbyDocumentElement.consumer ?? defaultConsumer());
      if (generation !== this.#generation) return; // released or retargeted meanwhile
      const attachment = this.#attachment = DocumentSessionStore.for(consumer).acquire(descriptor);
      const { session } = attachment;
      // The session ends the attachment itself when it blocks or is discarded.
      attachment.signal.addEventListener("abort", () => {
        if (this.#attachment !== attachment) return;
        this.#release();
        if (session.state === "blocked") this.#error(session.error, session);
      }, { once: true });
      if (session.state === "blocked") { attachment.release(); return; }
      void session.whenSynced.then(() => {
        if (this.#attachment !== attachment) return;
        this.#restoreInert();
        this.#resolveSynced();
        this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true,
          detail: { session, doc: session.doc, provider: session.provider, attachment, signal: attachment.signal } }));
      });
    } catch (error) {
      if (generation === this.#generation) this.#error(error);
    } finally {
      if (generation === this.#generation) this.#attaching = false;
    }
  }
  #release(): void {
    ++this.#generation;
    this.#attaching = false;
    const attachment = this.#attachment;
    this.#attachment = undefined;
    this.#whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });
    this.#holdInert();
    attachment?.release();
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
  #error(error: unknown, session?: DocumentAttachment["session"]): void {
    this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: { error, session } }));
  }
}
if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
