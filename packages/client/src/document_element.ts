// The element owns the document and provider; the application binds its editor
// after whenSynced or the bubbling yrby:synced event. DOM moves reuse the live
// document. Turbo snapshots carry CRDT state, including unacknowledged edits,
// so a restored element can replay it through the reliable delivery queue.
import * as Y from "yjs";
import { ActionCableProvider, type CableConsumer } from "./actioncable_provider.js";
import { toBase64, fromBase64 } from "./base64.js";

// Importable during SSR; registration and DOM operations remain browser-only.
const Base = (typeof HTMLElement === "undefined" ? class {} : HTMLElement) as typeof HTMLElement;
const SNAPSHOT_ATTRIBUTE = "data-yrby-snapshot";
let sharedConsumer: Promise<CableConsumer> | undefined;

function defaultConsumer(): Promise<CableConsumer> {
  // Cache the in-flight import, not just its result: multiple elements can
  // connect before the first import finishes. A failed import may be retried.
  return sharedConsumer ??= import("@rails/actioncable")
    .then((actioncable) => actioncable.createConsumer() as CableConsumer)
    .catch((error) => {
      sharedConsumer = undefined;
      throw error;
    });
}

export class YrbyDocumentElement extends Base {
  /** Assign before elements connect, for AnyCable or an asynchronously created consumer. */
  static consumer: CableConsumer | Promise<CableConsumer> | undefined;

  doc: Y.Doc = new Y.Doc();
  provider: ActionCableProvider | undefined;
  #connected = false;
  #generation = 0;
  #presence: Record<string, unknown> | null = null;
  #snapshotTaken = false;
  #destroyed = false;
  #resolveSynced!: () => void;
  #synced = false;
  #whenSynced = new Promise<void>((resolve) => { this.#resolveSynced = resolve; });

  /** Always available, including before the asynchronous consumer is ready. */
  get whenSynced(): Promise<void> {
    return this.#whenSynced;
  }

  async connectedCallback(): Promise<void> {
    this.#destroyed = false;
    this.#connected = true;
    const generation = ++this.#generation;
    this.ownerDocument?.addEventListener("turbo:before-cache", this.#beforeCache);
    if (this.provider) {
      this.#restorePresence();
      this.provider.connect();
      return;
    }

    try {
      const consumer = await (YrbyDocumentElement.consumer ?? defaultConsumer());
      if (!this.#connected || generation !== this.#generation) return;

      const provider = this.provider = new ActionCableProvider(this.doc, consumer, this.channelName, {
        grant: this.getAttribute("grant"),
        name: this.getAttribute("name"),
      });
      this.#restoreSnapshot();
      provider.connect();
      void provider.whenSynced.then(() => {
        if (this.provider !== provider || this.#synced) return;
        this.#synced = true;
        this.#resolveSynced();
        this.dispatchEvent(new CustomEvent("yrby:synced", {
          bubbles: true,
          detail: { doc: this.doc, provider },
        }));
      });
    } catch (error) {
      // Native custom-element callbacks don't await returned promises. Report
      // initialization failures through an event, not an unhandled rejection.
      if (!this.#connected || generation !== this.#generation) return;
      this.provider?.destroy();
      this.provider = undefined;
      this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: { error } }));
    }
  }

  disconnectedCallback(): void {
    this.#connected = false;
    ++this.#generation;
    this.ownerDocument?.removeEventListener("turbo:before-cache", this.#beforeCache);
    // Ordinary DOM moves finish in the same turn. Avoid tearing down their
    // subscriptions (and broadcasting a false departure) at all.
    queueMicrotask(() => {
      if (this.#connected) return;
      if (this.#snapshotTaken) {
        // Turbo kept the bytes in its cloned page. Release the old page's
        // subscriptions, awareness timer, and document listeners.
        this.destroy();
      } else {
        this.#presence = this.provider?.awareness.getLocalState() ?? null;
        this.provider?.disconnect();
      }
    });
  }

  /** Release a permanently removed element. Snapshot its state for possible reuse. */
  destroy(): void {
    if (this.#destroyed) return;
    this.#beforeCache();
    this.#destroyed = true;
    this.#connected = false;
    ++this.#generation;
    this.ownerDocument?.removeEventListener("turbo:before-cache", this.#beforeCache);
    this.provider?.destroy();
    this.provider = undefined;
    this.doc.destroy();
    this.doc = new Y.Doc();
    this.#synced = false;
    this.#whenSynced = new Promise<void>((resolve) => { this.#resolveSynced = resolve; });
  }

  #restorePresence(): void {
    if (this.#presence && this.provider?.awareness.getLocalState() === null) {
      this.provider.awareness.setLocalState(this.#presence);
    }
    this.#presence = null;
  }

  #beforeCache = (): void => {
    // Bind the saved bytes to their exact grant, attribute and channel. A
    // morph that retargets the element must never replay another document.
    const update = Y.encodeStateAsUpdate(this.doc);
    // A doc edited before its provider initialized has no observer/queue yet.
    const pending = this.provider ? this.provider.pendingUpdate : update;
    this.setAttribute(SNAPSHOT_ATTRIBUTE, JSON.stringify({
      identity: this.#identity(),
      update: toBase64(update),
      pending: pending && toBase64(pending),
    }));
    this.#snapshotTaken = true;
  };

  #restoreSnapshot(): void {
    const saved = this.getAttribute(SNAPSHOT_ATTRIBUTE);
    if (!saved) return;
    const snapshot = JSON.parse(saved);
    if (snapshot.identity === this.#identity()) {
      // Restore state without echoing the entire document, then explicitly
      // restore the local tail's delivery obligation. Applying an integrated
      // tail a second time alone would emit no event and never enqueue it.
      this.provider!.applyRemoteUpdate(fromBase64(snapshot.update));
      if (snapshot.pending) this.provider!.restorePendingUpdate(fromBase64(snapshot.pending));
    }
    this.removeAttribute(SNAPSHOT_ATTRIBUTE);
    this.#snapshotTaken = false;
  }

  #identity(): string {
    return JSON.stringify([this.channelName, this.getAttribute("grant"), this.getAttribute("name")]);
  }

  private get channelName(): string {
    return this.getAttribute("channel") || "Y::DocumentChannel";
  }
}

if (typeof customElements !== "undefined" && !customElements.get("yrby-document")) {
  customElements.define("yrby-document", YrbyDocumentElement);
}
