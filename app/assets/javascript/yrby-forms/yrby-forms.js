// src/index.ts
import"yrby-client/element";

// src/bindings.ts
var FIELDS_MAP = "fields";
function diffSplice(oldValue, newValue) {
  if (oldValue === newValue)
    return null;
  let start = 0;
  while (start < oldValue.length && start < newValue.length && oldValue[start] === newValue[start])
    start++;
  let oldEnd = oldValue.length;
  let newEnd = newValue.length;
  while (oldEnd > start && newEnd > start && oldValue[oldEnd - 1] === newValue[newEnd - 1]) {
    oldEnd--;
    newEnd--;
  }
  return { index: start, deleteCount: oldEnd - start, insert: newValue.slice(start, newEnd) };
}
var isCheckbox = (control) => control instanceof HTMLInputElement && control.type === "checkbox";
function bindLww(doc, name, control) {
  const map = doc.getMap(FIELDS_MAP);
  const origin = {};
  const read = () => isCheckbox(control) ? control.checked : control.value;
  const write = (value) => {
    if (isCheckbox(control))
      control.checked = value === true;
    else {
      const text = value == null ? "" : String(value);
      if (control.value !== text)
        control.value = text;
    }
  };
  const onInput = () => {
    if (map.get(name) === read())
      return;
    doc.transact(() => map.set(name, read()), origin);
  };
  control.addEventListener("input", onInput);
  control.addEventListener("change", onInput);
  const observer = (event, transaction) => {
    if (transaction.origin === origin || !event.keysChanged.has(name))
      return;
    write(map.get(name));
  };
  map.observe(observer);
  if (map.has(name))
    write(map.get(name));
  return () => {
    control.removeEventListener("input", onInput);
    control.removeEventListener("change", onInput);
    map.unobserve(observer);
  };
}
function bindText(doc, name, control) {
  const text = doc.getText(`${FIELDS_MAP}/${name}`);
  const origin = {};
  let shadow = control.value;
  if (text.length > 0)
    shadow = control.value = text.toString();
  const onInput = () => {
    const change = diffSplice(shadow, control.value);
    shadow = control.value;
    if (!change)
      return;
    doc.transact(() => {
      if (change.deleteCount > 0)
        text.delete(change.index, change.deleteCount);
      if (change.insert)
        text.insert(change.index, change.insert);
    }, origin);
  };
  control.addEventListener("input", onInput);
  const observer = (_event, transaction) => {
    if (transaction.origin === origin)
      return;
    const value = text.toString();
    if (control.value === value) {
      shadow = value;
      return;
    }
    const change = diffSplice(control.value, value);
    const caret = control.selectionStart;
    const focused = control.ownerDocument.activeElement === control;
    control.value = value;
    shadow = value;
    if (focused && change && caret != null) {
      const position = change.index <= caret ? Math.max(change.index, caret + change.insert.length - change.deleteCount) : caret;
      control.setSelectionRange(position, position);
    }
  };
  text.observe(observer);
  return () => {
    control.removeEventListener("input", onInput);
    text.unobserve(observer);
  };
}

// src/styles.ts
var STYLE_ID = "yrby-forms-styles";
function ensureStyles(doc) {
  if (doc.getElementById(STYLE_ID))
    return;
  const style = doc.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
collaborative-field { display: block; position: relative; }
collaborative-field[data-remote] :is(input, textarea, select) {
  outline: 2px solid var(--collaborative-field-color, #958DF1);
  outline-offset: 1px;
}
.collaborative-field-chip {
  position: absolute;
  top: 0;
  right: 0;
  transform: translateY(-100%);
  color: #fff;
  padding: 1px 6px;
  border-radius: 999px;
  font: 11px system-ui, sans-serif;
  pointer-events: none;
}
`;
  doc.head.appendChild(style);
}

// src/collaborative_field.ts
var FALLBACK_COLOR = "#958DF1";

class CollaborativeField extends HTMLElement {
  #host = null;
  #unbind = null;
  connectedCallback() {
    ensureStyles(this.ownerDocument);
    const host = this.closest("yrby-document, collaborative-fields");
    if (!host) {
      console.error("<collaborative-field> needs a <yrby-document> or <collaborative-fields> around it.");
      return;
    }
    this.#host = host;
    host.addEventListener("yrby:synced", this.#onSynced);
    if (host.current)
      this.#bind(host.current);
  }
  disconnectedCallback() {
    this.#host?.removeEventListener("yrby:synced", this.#onSynced);
    this.#host = null;
    this.#unbind?.();
  }
  #onSynced = (event) => {
    if (event.target === this.#host)
      this.#bind(event.detail);
  };
  #bind({ doc, lease, signal }) {
    this.#unbind?.();
    const control = this.querySelector("input:not([type=hidden]), textarea, select");
    const name = this.getAttribute("name");
    if (!control || !name) {
      console.error("<collaborative-field> needs a name and a form control.");
      return;
    }
    const unbindControl = this.getAttribute("tier") === "text" ? bindText(doc, name, control) : bindLww(doc, name, control);
    const keep = (event) => {
      if (event.target === control)
        event.preventDefault();
    };
    this.addEventListener("turbo:before-morph-element", keep);
    const unbindPresence = lease ? this.#bindPresence(name, lease) : () => {};
    const unbind = () => {
      if (this.#unbind !== unbind)
        return;
      this.#unbind = null;
      unbindControl();
      this.removeEventListener("turbo:before-morph-element", keep);
      unbindPresence();
    };
    this.#unbind = unbind;
    signal.addEventListener("abort", unbind, { once: true });
  }
  #bindPresence(name, lease) {
    const { userName, userColor } = this.#host.dataset;
    const user = { name: userName || "Anonymous", color: userColor || FALLBACK_COLOR };
    const onFocusin = () => lease.setPresence({ user, field: name });
    const onFocusout = () => lease.setPresence({ user, field: null });
    this.addEventListener("focusin", onFocusin);
    this.addEventListener("focusout", onFocusout);
    const awareness = lease.session.provider.awareness;
    const renderPresence = () => {
      const peers = [...awareness.getStates()].filter(([id, state]) => id !== awareness.clientID && state?.field === name).map(([, state]) => state.user ?? {});
      this.#renderPresence(peers);
    };
    awareness.on("update", renderPresence);
    renderPresence();
    return () => {
      this.removeEventListener("focusin", onFocusin);
      this.removeEventListener("focusout", onFocusout);
      awareness.off("update", renderPresence);
      this.#renderPresence([]);
    };
  }
  #renderPresence(peers) {
    for (const chip of this.querySelectorAll(".collaborative-field-chip"))
      chip.remove();
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

// src/collaborative_fields.ts
import * as Y from "yjs";
var SAVE_DELAY = 300;
var REMOTE = "remote";

class CollaborativeFields extends HTMLElement {
  static observedAttributes = ["value"];
  current;
  #form = null;
  #abort = null;
  #timer;
  connectedCallback() {
    const doc = new Y.Doc;
    this.#abort = new AbortController;
    const { signal } = this.#abort;
    this.current = { doc, signal };
    this.#merge(this.getAttribute("value"));
    this.#form = this.closest("form");
    this.#form?.addEventListener("formdata", this.#onFormData, { signal });
    doc.on("update", (_update, origin) => {
      if (origin !== REMOTE && this.hasAttribute("autosave"))
        this.#schedule();
    });
    this.dispatchEvent(new CustomEvent("yrby:synced", { detail: this.current, bubbles: true }));
  }
  disconnectedCallback() {
    if (this.#timer !== undefined)
      this.#save();
    this.#abort?.abort();
    this.current = undefined;
  }
  attributeChangedCallback(_name, _old, value) {
    this.#merge(value);
  }
  #merge(state) {
    if (this.current && state)
      Y.applyUpdate(this.current.doc, fromBase64(state), REMOTE);
  }
  #onFormData = ({ formData }) => {
    const name = this.getAttribute("name");
    if (name && this.current)
      formData.set(name, toBase64(Y.encodeStateAsUpdate(this.current.doc)));
  };
  #schedule() {
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => void this.#save(), SAVE_DELAY);
  }
  async#save() {
    clearTimeout(this.#timer);
    this.#timer = undefined;
    const form = this.#form;
    const doc = this.current?.doc;
    if (!form || !doc)
      return;
    const body = new URLSearchParams(new FormData(form));
    const response = await fetch(form.getAttribute("action") || location.href, {
      method: "POST",
      body,
      headers: { Accept: "text/html" }
    });
    if (!response.ok || this.current?.doc !== doc)
      return;
    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    for (const fields of page.querySelectorAll("collaborative-fields")) {
      if (fields.getAttribute("name") === this.getAttribute("name"))
        this.#merge(fields.getAttribute("value"));
    }
  }
}
var toBase64 = (bytes) => {
  let binary = "";
  for (const byte of bytes)
    binary += String.fromCharCode(byte);
  return btoa(binary);
};
var fromBase64 = (text) => Uint8Array.from(atob(text), (char) => char.charCodeAt(0));

// src/elements.ts
for (const [name, element] of [
  ["collaborative-field", CollaborativeField],
  ["collaborative-fields", CollaborativeFields]
]) {
  if (!customElements.get(name))
    customElements.define(name, element);
}
export {
  CollaborativeField,
  CollaborativeFields
};

//# debugId=4D1856F888688AB364756E2164756E21
//# sourceMappingURL=yrby-forms.js.map
