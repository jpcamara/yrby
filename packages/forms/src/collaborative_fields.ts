// <collaborative-fields>: holds the fields' document for a form with no
// connection. The document's state is Base64 in the element's `value`
// attribute, where the server renders it. The element adds the current state
// to the form's data under its `name`, so a submit carries every edit, and the
// server merges it with the state it holds.
//
// When the `value` attribute changes, as it does when Turbo morphs the page,
// the new state is merged into the document. With `autosave`, each edit posts
// the form after a short pause and merges the state in the page that answers.
import * as Y from "yjs";

const SAVE_DELAY = 300;
// The origin of states read from the server. Autosave skips them.
const REMOTE = "remote";

export class CollaborativeFields extends HTMLElement {
  static observedAttributes = ["value"];

  // What a <collaborative-field> binds to, as <yrby-document> has it.
  current?: { doc: Y.Doc; signal: AbortSignal };
  #form: HTMLFormElement | null = null;
  #abort: AbortController | null = null;
  #timer: ReturnType<typeof setTimeout> | undefined;

  connectedCallback(): void {
    const doc = new Y.Doc();
    this.#abort = new AbortController();
    const { signal } = this.#abort;
    this.current = { doc, signal };
    this.#merge(this.getAttribute("value"));

    this.#form = this.closest("form");
    this.#form?.addEventListener("formdata", this.#onFormData, { signal });
    doc.on("update", (_update: Uint8Array, origin: unknown) => {
      if (origin !== REMOTE && this.hasAttribute("autosave")) this.#schedule();
    });
    this.dispatchEvent(new CustomEvent("yrby:synced", { detail: this.current, bubbles: true }));
  }

  disconnectedCallback(): void {
    if (this.#timer !== undefined) void this.#save(); // an edit is waiting
    this.#abort?.abort();
    this.current = undefined;
  }

  attributeChangedCallback(_name: string, _old: string | null, value: string | null): void {
    this.#merge(value);
  }

  #merge(state: string | null): void {
    if (this.current && state) Y.applyUpdate(this.current.doc, fromBase64(state), REMOTE);
  }

  #onFormData = ({ formData }: FormDataEvent): void => {
    const name = this.getAttribute("name");
    if (name && this.current) formData.set(name, toBase64(Y.encodeStateAsUpdate(this.current.doc)));
  };

  #schedule(): void {
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => void this.#save(), SAVE_DELAY);
  }

  // Posts the form as a submit would. The answer is the page the server
  // renders next, which holds the state it stored.
  async #save(): Promise<void> {
    clearTimeout(this.#timer);
    this.#timer = undefined;
    const form = this.#form;
    const doc = this.current?.doc;
    if (!form || !doc) return;

    const body = new URLSearchParams(new FormData(form) as unknown as Record<string, string>);
    const response = await fetch(form.getAttribute("action") || location.href, {
      method: "POST",
      body,
      headers: { Accept: "text/html" },
    });
    if (!response.ok || this.current?.doc !== doc) return;

    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    for (const fields of page.querySelectorAll("collaborative-fields")) {
      if (fields.getAttribute("name") === this.getAttribute("name")) this.#merge(fields.getAttribute("value"));
    }
  }
}

const toBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
};

const fromBase64 = (text: string): Uint8Array => Uint8Array.from(atob(text), (char) => char.charCodeAt(0));
