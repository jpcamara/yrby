"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.CollaborativeField = void 0;
const bindings_js_1 = require("./bindings.js");
const styles_js_1 = require("./styles.js");
const FALLBACK_COLOR = "#958DF1";
class CollaborativeField extends HTMLElement {
    #teardown = null;
    connectedCallback() {
        (0, styles_js_1.ensureStyles)(this.ownerDocument);
        const form = this.closest("collaborative-form");
        const control = this.querySelector("input, textarea, select");
        const name = this.getAttribute("name");
        if (!form?.provider || !control || !name) {
            console.error("<collaborative-field> needs a name, a form control, and an enclosing <collaborative-form>.");
            return;
        }
        const unbind = this.getAttribute("tier") === "text"
            ? (0, bindings_js_1.bindText)(form.doc, name, control)
            : (0, bindings_js_1.bindLww)(form.doc, name, control);
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
    disconnectedCallback() {
        this.#teardown?.();
        this.#teardown = null;
    }
    #renderPresence(awareness, name) {
        const peers = [...awareness.getStates()].filter(([id, state]) => id !== awareness.clientID && state?.field === name);
        for (const chip of this.querySelectorAll(".collaborative-field-chip"))
            chip.remove();
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
exports.CollaborativeField = CollaborativeField;
