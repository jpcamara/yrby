import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import * as Y from "yjs";

// The elements need a DOM, and jsdom provides it. The globals must be in
// place before the package is imported, because importing registers the
// elements.
const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "https://app.example/tickets/1" });
for (const key of [
  "window",
  "document",
  "location",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLSelectElement",
  "customElements",
  "CustomEvent",
  "Event",
  "AbortController",
  "DOMParser",
]) {
  globalThis[key] = dom.window[key];
}
// A browser fires `formdata` on the form when a FormData is built from it.
// jsdom does not, so this does.
globalThis.FormData = class extends dom.window.FormData {
  constructor(form) {
    super(form);
    form.dispatchEvent(Object.assign(new dom.window.Event("formdata"), { formData: this }));
  }
};
await import("../dist/column.js");

const base64 = (doc) => Buffer.from(Y.encodeStateAsUpdate(doc)).toString("base64");
const decode = (state) => {
  const doc = new Y.Doc();
  Y.applyUpdate(doc, Buffer.from(state, "base64"));
  return doc;
};
const fire = (el, type) => el.dispatchEvent(new dom.window.Event(type, { bubbles: true, cancelable: true }));

// The stored document: what the server would render into the form.
function stored() {
  const doc = new Y.Doc();
  doc.getMap("fields").set("status", "active");
  doc.getText("fields/description").insert(0, "Stored text");
  return doc;
}

// Adds a form as the form helper renders it in column mode.
function makeForm(t, { state = "", autosave = false } = {}) {
  const form = document.createElement("form");
  form.setAttribute("action", "/tickets/1");
  form.innerHTML = `
    <input type="hidden" name="_method" value="patch">
    <collaborative-fields name="ticket[fields_ydoc]" value="${state}"${autosave ? " autosave" : ""}>
      <collaborative-field name="status" tier="lww">
        <select name="ticket[status]"><option value=""></option><option value="active">active</option><option value="done">done</option></select>
      </collaborative-field>
      <collaborative-field name="description" tier="text"><textarea name="ticket[description]"></textarea></collaborative-field>
    </collaborative-fields>
  `;
  document.body.appendChild(form);
  t.after(() => form.remove());
  const fields = form.querySelector("collaborative-fields");
  const control = (name) => form.querySelector(`collaborative-field[name="${name}"]`).querySelector("textarea, select");
  const type = (name, value) => {
    control(name).value = value;
    fire(control(name), "input");
  };
  return { form, fields, control, type };
}

test("the fields show the state in the value attribute", (t) => {
  const { control } = makeForm(t, { state: base64(stored()) });

  assert.equal(control("status").value, "active");
  assert.equal(control("description").value, "Stored text");
});

test("the form's data carries the document with every edit", (t) => {
  const { form, type } = makeForm(t, { state: base64(stored()) });

  type("description", "Stored text, edited");
  const data = new FormData(form);

  assert.equal(data.get("ticket[description]"), "Stored text, edited");
  assert.equal(decode(data.get("ticket[fields_ydoc]")).getText("fields/description").toString(), "Stored text, edited");
});

test("a new record's form starts an empty document", (t) => {
  const { form, type } = makeForm(t);

  type("description", "First words");

  const doc = decode(new FormData(form).get("ticket[fields_ydoc]"));
  assert.equal(doc.getText("fields/description").toString(), "First words");
});

test("a new value attribute merges into the document and the controls", (t) => {
  const state = base64(stored());
  const a = makeForm(t, { state });
  const b = makeForm(t, { state });

  a.type("description", "Stored text, from A");
  b.type("description", "From B: Stored text");
  b.control("status").value = "done";
  fire(b.control("status"), "change");
  // The server merges what each form sends and renders the result to both.
  const merged = decode(new FormData(a.form).get("ticket[fields_ydoc]"));
  Y.applyUpdate(merged, Buffer.from(new FormData(b.form).get("ticket[fields_ydoc]"), "base64"));
  for (const { fields } of [a, b]) fields.setAttribute("value", base64(merged));

  for (const { control } of [a, b]) {
    assert.equal(control("description").value, "From B: Stored text, from A");
    assert.equal(control("status").value, "done");
  }
});

test("autosave posts the form after an edit and merges the page that answers", async (t) => {
  const server = stored();
  const requests = [];
  t.mock.method(globalThis, "fetch", async (url, { method, body }) => {
    requests.push({ url, method, params: Object.fromEntries(body) });
    Y.applyUpdate(server, Buffer.from(body.get("ticket[fields_ydoc]"), "base64"));
    server.getText("fields/description").insert(0, "Someone else: "); // an edit this form has not seen
    const page = `<form><collaborative-fields name="ticket[fields_ydoc]" value="${base64(server)}"></collaborative-fields></form>`;
    return { ok: true, text: async () => page };
  });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { control, type } = makeForm(t, { state: base64(server), autosave: true });

  type("description", "Stored text!");
  type("description", "Stored text!!");
  t.mock.timers.tick(300);
  for (let i = 0; i < 8; i++) await Promise.resolve();

  assert.equal(requests.length, 1, "edits within the pause make one request");
  assert.deepEqual([requests[0].url, requests[0].method], ["/tickets/1", "POST"]);
  assert.equal(requests[0].params._method, "patch");
  assert.equal(requests[0].params["ticket[description]"], "Stored text!!");
  assert.equal(control("description").value, "Someone else: Stored text!!");
  t.mock.timers.tick(300);
  assert.equal(requests.length, 1, "merging the answer is not an edit");
});

test("without autosave an edit posts nothing", (t) => {
  const fetch = t.mock.method(globalThis, "fetch", async () => ({ ok: false }));
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { type } = makeForm(t, { state: base64(stored()) });

  type("description", "Stored text!");
  t.mock.timers.tick(300);

  assert.equal(fetch.mock.callCount(), 0);
});

test("removing the form saves an edit that was waiting", (t) => {
  const fetch = t.mock.method(globalThis, "fetch", async () => ({ ok: false }));
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { form, type } = makeForm(t, { state: base64(stored()), autosave: true });

  type("description", "Stored text!");
  form.remove();

  assert.equal(fetch.mock.callCount(), 1);
  assert.equal(fetch.mock.calls[0].arguments[1].body.get("ticket[description]"), "Stored text!");
});

test("a Turbo morph leaves a bound control alone", (t) => {
  const { form, control } = makeForm(t, { state: base64(stored()) });

  assert.equal(fire(control("description"), "turbo:before-morph-element"), false, "the control's morph is canceled");
  assert.equal(fire(form.querySelector("collaborative-fields"), "turbo:before-morph-element"), true);
});
