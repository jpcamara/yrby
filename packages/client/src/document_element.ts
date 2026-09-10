import { type CableConsumer } from "./actioncable_provider.js";
import { DocumentSessionStore, type DocumentAttachment } from "./document_session.js";
import { registerDocumentMount } from "./turbo_adapter.js";

const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;
let sharedConsumer: Promise<CableConsumer> | undefined;
function defaultConsumer(): Promise<CableConsumer> {
  return sharedConsumer ??= import("@rails/actioncable")
    .then(ac => ac.createConsumer() as CableConsumer)
    .catch(error => { sharedConsumer = undefined; throw error; });
}

/** An editor attachment. The session store owns documents and pending delivery. */
export class YrbyDocumentElement extends Base {
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;
  static observedAttributes = ["grant", "name", "channel", "refresh"];
  #attachment: DocumentAttachment | undefined;
  #connected = false;
  #active = false;
  #starting = false;
  #generation = 0;
  #unregister: (() => void) | undefined;
  #holdingInert = false;
  #previousInert = false;
  #resolveSynced!: () => void;
  #whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });
  get session() { return this.#attachment?.session; }
  get doc() { return this.session?.doc; }
  get provider() { return this.session?.provider; }
  get whenSynced(): Promise<void> { return this.#whenSynced; }

  connectedCallback(): void {
    this.#connected = true;
    this.#unregister ??= registerDocumentMount(this);
  }
  disconnectedCallback(): void {
    this.#connected = false;
    // Same-turn moves keep their binding, queue, undo history, and presence.
    queueMicrotask(() => { if (!this.#connected) this.destroy(); });
  }
  attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue === newValue || !this.#connected) return;
    // The refresh URL is read when the session is acquired and is not part of
    // its identity, so changing it does not rebind the editor.
    if (name === "refresh") return;
    this.#release();
    const generation = this.#generation;
    queueMicrotask(() => { if (generation === this.#generation) void this.#attach(); });
  }

  /** @internal Called by the browser adapter; independent of Turbo event names. */
  activate(): void { this.#active = true; void this.#attach(); }
  /** @internal */
  deactivate(): void { this.#active = false; this.#release(); }
  /** Release the editor attachment. Unsaved work remains owned by its session. */
  destroy(): void {
    this.#connected = false;
    this.deactivate();
    const unregister = this.#unregister;
    this.#unregister = undefined;
    unregister?.();
  }

  async #attach(): Promise<void> {
    if (!this.#connected || !this.#active || this.#starting || this.#attachment) return;
    this.#holdInert();
    this.#starting = true;
    const generation = this.#generation;
    const descriptor = { channel: this.getAttribute("channel") || undefined,
      grant: this.getAttribute("grant") || "", name: this.getAttribute("name") || "",
      refresh: this.getAttribute("refresh") || undefined };
    try {
      const consumer = await (YrbyDocumentElement.consumer ?? defaultConsumer());
      if (!this.#connected || !this.#active || generation !== this.#generation) return;
      const attachment = this.#attachment = DocumentSessionStore.for(consumer).acquire(descriptor);
      const session = attachment.session;
      attachment.signal.addEventListener("abort", () => {
        if (this.#attachment !== attachment) return;
        this.#release();
        if (session.state === "blocked") this.#error(session.error, session);
      }, { once: true });
      if (session.state === "blocked") {
        this.#release();
        this.#error(session.error, session);
        return;
      }
      void session.whenSynced.then(() => {
        if (this.#attachment !== attachment || attachment.signal.aborted || !this.#connected || !this.#active) return;
        this.#restoreInert();
        this.#resolveSynced();
        this.dispatchEvent(new CustomEvent("yrby:synced", { bubbles: true,
          detail: { session, doc: session.doc, provider: session.provider, attachment, signal: attachment.signal } }));
      });
    } catch (error) {
      if (generation === this.#generation && this.#connected) this.#error(error);
    } finally {
      if (generation === this.#generation) this.#starting = false;
    }
  }
  #release(): void {
    ++this.#generation;
    const attachment = this.#attachment;
    this.#attachment = undefined;
    if (attachment || this.#starting) {
      this.#whenSynced = new Promise<void>(resolve => { this.#resolveSynced = resolve; });
    }
    this.#starting = false;
    this.#holdInert();
    attachment?.release();
  }
  #holdInert(): void {
    if (!this.#holdingInert) {
      // A cached clone carries the library's inert attribute, not its JS fields.
      const saved = this.getAttribute("data-yrby-inert");
      this.#previousInert = saved === null ? this.inert : saved === "true";
      this.setAttribute("data-yrby-inert", String(this.#previousInert));
    }
    this.#holdingInert = true;
    this.inert = true;
  }
  #restoreInert(): void {
    if (this.#holdingInert) this.inert = this.#previousInert;
    this.#holdingInert = false;
    this.removeAttribute("data-yrby-inert");
  }
  #error(error: unknown, session?: DocumentAttachment["session"]): void {
    this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: { error, session } }));
  }
}
if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
