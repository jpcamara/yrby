// <collaborative-field>: binds the one form control inside it to the
// enclosing <collaborative-form>'s document. tier="lww" binds the control's
// value to the shared map entry under `name`; tier="text" binds a text
// control to the `fields/<name>` Y.Text (see bindings.ts). While a remote
// peer focuses the same field, the wrapper shows their color as an outline
// and their name as a chip.
import type { Awareness } from "y-protocols/awareness";
import { bindLww, bindText, type BoundControl } from "./bindings.js";
import type { CollaborativeForm } from "./collaborative_form.js";
import { ensureStyles } from "./styles.js";

const FALLBACK_COLOR = "#958DF1";

export class CollaborativeField extends HTMLElement {
  #teardown: (() => void) | null = null;

  connectedCallback(): void {
    ensureStyles(this.ownerDocument);
    const form = this.closest("collaborative-form") as CollaborativeForm | null;
    const control = this.querySelector<BoundControl>("input, textarea, select");
    const name = this.getAttribute("name");
    if (!form?.provider || !control || !name) {
      console.error("<collaborative-field> needs a name, a form control, and an enclosing <collaborative-form>.");
      return;
    }

    const unbind =
      this.getAttribute("tier") === "text"
        ? bindText(form.doc, name, control as HTMLInputElement | HTMLTextAreaElement)
        : bindLww(form.doc, name, control);

    // Presence: announce which field we're in; render peers in this one.
    const awareness = form.provider.awareness;
    const onFocusin = () => awareness.setLocalStateField("field", name);
    const onFocusout = () => awareness.setLocalStateField("field", null);
    this.addEventListener("focusin", onFocusin);
    this.addEventListener("focusout", onFocusout);
    const renderPresence = () => this.#renderPresence(awareness, name);
    awareness.on("update", renderPresence);
    renderPresence();

    this.#teardown = () => {
      unbind();
      this.removeEventListener("focusin", onFocusin);
      this.removeEventListener("focusout", onFocusout);
      awareness.off("update", renderPresence);
    };
  }

  disconnectedCallback(): void {
    this.#teardown?.();
    this.#teardown = null;
  }

  #renderPresence(awareness: Awareness, name: string): void {
    const peers = [...awareness.getStates()].filter(
      ([id, state]) => id !== awareness.clientID && state?.field === name
    );
    for (const chip of this.querySelectorAll(".collaborative-field-chip")) chip.remove();
    if (peers.length === 0) {
      this.removeAttribute("data-remote");
      this.style.removeProperty("--collaborative-field-color");
      return;
    }
    this.setAttribute("data-remote", "");
    this.style.setProperty("--collaborative-field-color", String(peers[0][1].color ?? FALLBACK_COLOR));
    for (const [, state] of peers) {
      const chip = this.ownerDocument.createElement("span");
      chip.className = "collaborative-field-chip";
      chip.textContent = String(state.name ?? "Anonymous");
      chip.style.background = String(state.color ?? FALLBACK_COLOR);
      this.appendChild(chip);
    }
  }
}
