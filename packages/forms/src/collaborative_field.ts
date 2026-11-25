// <collaborative-field>: binds the form control inside it to the document of
// the <yrby-document> around it. tier="lww" binds the control's value to the
// shared map entry under `name`. tier="text" binds a text control to the
// `fields/<name>` Y.Text (see bindings.ts). While another person has the same
// field focused, the wrapper shows their color as an outline and their name
// as a chip.
import type * as Y from "yjs";
import type { DocumentLease } from "yrby-client";
import { bindLww, bindText, type BoundControl } from "./bindings.js";
import { ensureStyles } from "./styles.js";

const FALLBACK_COLOR = "#958DF1";

// The parts of the yrby:synced detail a field uses.
type Synced = { doc: Y.Doc; lease: DocumentLease; signal: AbortSignal };
// <yrby-document>. `current` is the detail of the session it is bound to.
type DocumentElement = HTMLElement & { current?: Synced };

export class CollaborativeField extends HTMLElement {
  #host: DocumentElement | null = null;
  #unbind: (() => void) | null = null;

  connectedCallback(): void {
    ensureStyles(this.ownerDocument);
    const host = this.closest<DocumentElement>("yrby-document");
    if (!host) {
      console.error("<collaborative-field> needs a <yrby-document> around it.");
      return;
    }
    this.#host = host;
    host.addEventListener("yrby:synced", this.#onSynced);
    // The document may have synced before this field was added.
    if (host.current) this.#bind(host.current);
  }

  disconnectedCallback(): void {
    this.#host?.removeEventListener("yrby:synced", this.#onSynced);
    this.#host = null;
    this.#unbind?.();
  }

  // The event bubbles, so a document nested inside this one is ignored.
  #onSynced = (event: Event): void => {
    if (event.target === this.#host) this.#bind((event as CustomEvent<Synced>).detail);
  };

  #bind({ doc, lease, signal }: Synced): void {
    this.#unbind?.();
    // Rails renders a hidden input before a checkbox.
    const control = this.querySelector<BoundControl>("input:not([type=hidden]), textarea, select");
    const name = this.getAttribute("name");
    if (!control || !name) {
      console.error("<collaborative-field> needs a name and a form control.");
      return;
    }

    const unbindControl =
      this.getAttribute("tier") === "text"
        ? bindText(doc, name, control as HTMLInputElement | HTMLTextAreaElement)
        : bindLww(doc, name, control);

    // Presence says which field this person is in. The name and color come
    // from the form helper, as data attributes on <yrby-document>.
    const { userName, userColor } = this.#host!.dataset;
    const user = { name: userName || "Anonymous", color: userColor || FALLBACK_COLOR };
    const onFocusin = () => lease.setPresence({ user, field: name });
    const onFocusout = () => lease.setPresence({ user, field: null });
    this.addEventListener("focusin", onFocusin);
    this.addEventListener("focusout", onFocusout);

    const awareness = lease.session.provider.awareness;
    const renderPresence = () => {
      const peers = [...awareness.getStates()]
        .filter(([id, state]) => id !== awareness.clientID && state?.field === name)
        .map(([, state]) => state.user ?? {});
      this.#renderPresence(peers);
    };
    awareness.on("update", renderPresence);
    renderPresence();

    const unbind = () => {
      if (this.#unbind !== unbind) return;
      this.#unbind = null;
      unbindControl();
      this.removeEventListener("focusin", onFocusin);
      this.removeEventListener("focusout", onFocusout);
      awareness.off("update", renderPresence);
      this.#renderPresence([]);
    };
    this.#unbind = unbind;
    // The lease ends when the page is cached, the element is removed, or the
    // session blocks. The field binds again on the next yrby:synced.
    signal.addEventListener("abort", unbind, { once: true });
  }

  #renderPresence(peers: { name?: unknown; color?: unknown }[]): void {
    for (const chip of this.querySelectorAll(".collaborative-field-chip")) chip.remove();
    if (peers.length === 0) {
      this.removeAttribute("data-remote");
      this.style.removeProperty("--collaborative-field-color");
      return;
    }
    this.setAttribute("data-remote", "");
    this.style.setProperty("--collaborative-field-color", String(peers[0].color ?? FALLBACK_COLOR));
    for (const peer of peers) {
      const chip = this.ownerDocument.createElement("span");
      chip.className = "collaborative-field-chip";
      chip.textContent = String(peer.name ?? "Anonymous");
      chip.style.background = String(peer.color ?? FALLBACK_COLOR);
      this.appendChild(chip);
    }
  }
}
