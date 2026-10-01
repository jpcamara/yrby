// Turbo and Turbolinks integration. An editor binds only while its page is
// live. Cached snapshots and previews hold no document or delivery queue, since
// the session store keeps those.
export interface DocumentMount {
  readonly ownerDocument: Document;
  readonly isConnected: boolean;
  activate(): void;
  deactivate(): void;
}
const adapters = new WeakMap<Document, TurboAdapter>();
// Turbo (Hotwire) and Turbolinks 5 fire the same lifecycle events under different names.
const CACHE_EVENTS = ["turbo:before-cache", "turbolinks:before-cache"];
const RENDER_EVENTS = ["turbo:render", "turbo:load", "turbo:fetch-request-error", "turbolinks:render", "turbolinks:load"];
const PREVIEW_ATTRIBUTES = ["data-turbo-preview", "data-turbolinks-preview"];

export function registerDocumentMount(mount: DocumentMount): () => void {
  let adapter = adapters.get(mount.ownerDocument);
  if (!adapter) adapters.set(mount.ownerDocument, adapter = new TurboAdapter(mount.ownerDocument));
  adapter.mounts.add(mount);
  adapter.reconcile();
  return () => {
    adapter.mounts.delete(mount);
    if (!adapter.mounts.size) adapter.destroy();
  };
}

/** Tears down the adapter, for application shutdown or tests. */
export function disconnectTurbo(document: Document): void { adapters.get(document)?.destroy(); }

type AdapterState = { phase: "active"; timer?: ReturnType<typeof setTimeout> } | { phase: "destroyed" };

class TurboAdapter {
  readonly mounts = new Set<DocumentMount>();
  #state: AdapterState = { phase: "active" };
  constructor(readonly document: Document) {
    for (const event of CACHE_EVENTS) document.addEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS) document.addEventListener(event, this.reconcile);
  }
  reconcile = (): void => {
    if (this.#state.phase !== "active") return;
    const html = this.document.documentElement;
    const preview = PREVIEW_ATTRIBUTES.some(attribute => html?.hasAttribute(attribute));
    for (const mount of this.mounts) {
      if (!mount.isConnected || preview) mount.deactivate();
      else mount.activate();
    }
  };
  #beforeCache = (): void => {
    const state = this.#state;
    if (state.phase !== "active") return;
    for (const mount of this.mounts) mount.deactivate();
    if (this.#state !== state) return;
    // A canceled or failed navigation fires no render or load event, so we
    // reconcile ourselves after Turbo finishes cloning the snapshot. The clone
    // takes two turns, which is why the timers are nested.
    clearTimeout(state.timer);
    state.timer = setTimeout(() => {
      if (this.#state === state) state.timer = setTimeout(this.reconcile, 0);
    }, 0);
  };
  destroy(): void {
    const state = this.#state;
    if (state.phase === "destroyed") return;
    this.#state = { phase: "destroyed" };
    clearTimeout(state.timer);
    // Leave the registry first so cleanup callbacks can register a replacement
    // adapter for this document.
    adapters.delete(this.document);
    for (const event of CACHE_EVENTS) this.document.removeEventListener(event, this.#beforeCache);
    for (const event of RENDER_EVENTS) this.document.removeEventListener(event, this.reconcile);
    for (const mount of this.mounts) mount.deactivate();
    this.mounts.clear();
  }
}
