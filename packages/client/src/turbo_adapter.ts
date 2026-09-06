// Browser policy only. Turbo's cached DOM never owns a document or delivery queue.
export interface DocumentMount {
  readonly ownerDocument: Document;
  readonly isConnected: boolean;
  activate(): void;
  deactivate(): void;
  removeAttribute(name: string): void;
}
const adapters = new WeakMap<Document, TurboAdapter>();

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

/** Explicit adapter teardown, useful when an application shuts down or in tests. */
export function disconnectTurbo(document: Document): void { adapters.get(document)?.destroy(); }

class TurboAdapter {
  readonly mounts = new Set<DocumentMount>();
  #destroyed = false;
  #timer: ReturnType<typeof setTimeout> | undefined;
  readonly #events = ["turbo:render", "turbo:load", "turbo:fetch-request-error"];
  constructor(readonly document: Document) {
    document.addEventListener("turbo:before-cache", this.#beforeCache);
    for (const event of this.#events) document.addEventListener(event, this.reconcile);
  }
  reconcile = (): void => {
    const preview = this.document.documentElement?.hasAttribute("data-turbo-preview");
    for (const mount of this.mounts) {
      mount.removeAttribute("data-yrby-snapshot");
      if (!mount.isConnected || preview) mount.deactivate();
      else mount.activate();
    }
  };
  #beforeCache = (): void => {
    for (const mount of this.mounts) mount.deactivate();
    // Allow Turbo's next-turn clone to finish. A canceled/failed navigation
    // must not leave a still-mounted page permanently unbound.
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => { this.#timer = setTimeout(this.reconcile, 0); }, 0);
  };
  destroy(): void {
    if (this.#destroyed) return;
    this.#destroyed = true;
    clearTimeout(this.#timer);
    this.document.removeEventListener("turbo:before-cache", this.#beforeCache);
    for (const event of this.#events) this.document.removeEventListener(event, this.reconcile);
    for (const mount of this.mounts) mount.deactivate();
    this.mounts.clear();
    adapters.delete(this.document);
  }
}
