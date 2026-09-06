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

  static observedAttributes = ["grant", "name", "channel"];

  doc: Y.Doc = new Y.Doc();
  provider: ActionCableProvider | undefined;
  #boundIdentity: string | undefined;
  #preview = false;
  #previousInert = false;
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
    this.ownerDocument?.addEventListener("turbo:render", this.#afterRender);
    if (this.ownerDocument?.documentElement?.hasAttribute("data-turbo-preview")) {
      if (!this.#preview) this.#previousInert = this.inert;
      this.#preview = true;
      this.inert = true;
      this.provider?.disconnect();
      return;
    }
    if (this.#preview) {
      this.inert = this.#previousInert;
      this.#preview = false;
    }
    this.#boundIdentity ??= this.#identity();
    if (!this.#checkIdentity()) return;
    if (this.provider) {
      this.#restorePresence();
      this.provider.connect();
      this.#watchSync(this.provider);
      return;
    }

    try {
      const consumer = await (YrbyDocumentElement.consumer ?? defaultConsumer());
      if (!this.#connected || generation !== this.#generation || !this.#checkIdentity()) return;

      const provider = this.provider = new ActionCableProvider(this.doc, consumer, this.channelName, {
        grant: this.getAttribute("grant"),
        name: this.getAttribute("name"),
      });
      this.#restoreSnapshot();
      provider.connect();
      this.#watchSync(provider);
    } catch (error) {
      // Native custom-element callbacks don't await returned promises. Report
      // initialization failures through an event, not an unhandled rejection.
      if (!this.#connected || generation !== this.#generation) return;
      if (this.provider) this.#beforeCache();
      this.provider?.destroy();
      this.provider = undefined;
      this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: { error } }));
    }
  }

  #watchSync(provider: ActionCableProvider): void {
    void provider.whenSynced.then(() => {
      if (this.provider !== provider || this.#synced || this.#preview || this.#identity() !== this.#boundIdentity) return;
      this.#synced = true;
      this.#resolveSynced();
      this.dispatchEvent(new CustomEvent("yrby:synced", {
        bubbles: true,
        detail: { doc: this.doc, provider },
      }));
    });
  }

  // A document's authorization is immutable for its lifetime. Applications
  // must replace the element (or destroy it first) when changing documents.
  attributeChangedCallback(_name: string, oldValue: string | null, newValue: string | null): void {
    if (oldValue !== newValue && this.#connected) void this.connectedCallback();
  }

  #checkIdentity(): boolean {
    if (this.#identity() === this.#boundIdentity) return true;
    this.provider?.disconnect();
    this.dispatchEvent(new CustomEvent("yrby:error", { bubbles: true, detail: {
      error: new Error("A connected yrby-document cannot change grant, name, or channel; replace it or call destroy() first."),
    } }));
    return false;
  }

  #afterRender = (): void => {
    if (this.#preview && this.#connected && !this.ownerDocument?.documentElement?.hasAttribute("data-turbo-preview")) {
      void this.connectedCallback();
    }
  };

  disconnectedCallback(): void {
    this.#connected = false;
    ++this.#generation;
    this.ownerDocument?.removeEventListener("turbo:before-cache", this.#beforeCache);
    this.ownerDocument?.removeEventListener("turbo:render", this.#afterRender);
    // Ordinary DOM moves finish in the same turn. Avoid tearing down their
    // subscriptions (and broadcasting a false departure) at all.
    queueMicrotask(() => {
      if (this.#connected) return;
      if (this.#snapshotTaken || this.#preview) {
        // A fresh response can mint a different grant for the same document.
        // Finish the old queue under its original grant, never the new one.
        this.#dispose(true);
      } else {
        this.#presence = this.provider?.awareness.getLocalState() ?? null;
        this.provider?.disconnect();
      }
    });
  }

  /** Release a permanently removed element. Snapshot its state for possible reuse. */
  destroy(): void {
    this.#dispose(false);
  }

  #dispose(finishDelivery: boolean): void {
    if (this.#destroyed) return;
    // A transient preview never loaded its snapshot into this.doc.
    if (!this.#preview || this.provider) this.#beforeCache();
    if (this.#preview) this.inert = this.#previousInert;
    this.#preview = false;
    this.#destroyed = true;
    this.#connected = false;
    ++this.#generation;
    this.ownerDocument?.removeEventListener("turbo:before-cache", this.#beforeCache);
    this.ownerDocument?.removeEventListener("turbo:render", this.#afterRender);
    const { provider, doc } = this;
    if (finishDelivery && provider?.hasPending) {
      // The detached editor is gone, but its delivery obligation remains.
      // Keep only this original subscription until ack; no preview can edit it.
      provider.awareness.setLocalState(null);
      provider.disconnect();
      provider.connect();
      const release = (): void => {
        off();
        provider.destroy();
        doc.destroy();
      };
      const off = provider.onStatusChange(({ status }) => {
        if (status === "disconnected") release();
      });
      void (async () => {
        while (provider.hasPending) await provider.whenAcknowledged;
        release();
      })();
    } else {
      provider?.destroy();
      doc.destroy();
    }
    this.provider = undefined;
    this.doc = new Y.Doc();
    this.#boundIdentity = undefined;
    this.#presence = null;
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
    if (this.#preview && !this.provider) return;
    const identity = this.#boundIdentity ?? this.#identity();
    const update = Y.encodeStateAsUpdate(this.doc);
    // A doc edited before its provider initialized has no observer/queue yet.
    const pending = this.provider ? this.provider.pendingUpdate : update;
    this.setAttribute(SNAPSHOT_ATTRIBUTE, JSON.stringify({
      identity,
      update: toBase64(update),
      pending: pending && toBase64(pending),
    }));
    this.#snapshotTaken = true;
  };

  #restoreSnapshot(): void {
    const saved = this.getAttribute(SNAPSHOT_ATTRIBUTE);
    if (saved) {
      const snapshot = JSON.parse(saved);
      if (snapshot.identity === this.#boundIdentity) {
        // Restore full state without echoing it; queue only its local tail.
        this.provider!.applyRemoteUpdate(fromBase64(snapshot.update));
        if (snapshot.pending) this.provider!.restorePendingUpdate(fromBase64(snapshot.pending));
      }
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
