import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { encodeAwarenessUpdate, applyAwarenessUpdate } from "y-protocols/awareness";
import { MessageType } from "yrby-client";

// The elements need a DOM; jsdom provides it. Globals must be in place
// before the package is imported (registration happens at import).
const dom = new JSDOM("<!doctype html><html><body></body></html>");
for (const key of [
  "window",
  "document",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLSelectElement",
  "customElements",
  "Event",
  "FocusEvent",
  "Node",
]) {
  globalThis[key] = dom.window[key];
}
await import("../dist/index.js");

// A fake ActionCable consumer, the same shape as yrby-client's tests: no
// transport, frames delivered by hand.
function fakeConsumer() {
  const calls = { send: [] };
  let sub = null;
  return {
    calls,
    get subscription() {
      return sub;
    },
    deliverConnected: () => sub.connected(),
    deliverReceived: (msg) => sub.received(msg),
    subscriptions: {
      create(params, mixin) {
        sub = {
          identifier: JSON.stringify(params),
          send: (data) => calls.send.push(data),
          unsubscribe: () => {},
          ...mixin,
        };
        return sub;
      },
    },
  };
}

// The envelope a server sends to say "you're caught up": a Sync frame
// carrying SyncStep2 with the peer's full state.
function syncStep2Envelope(peerDoc) {
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MessageType.Sync);
  encoding.writeVarUint(e, 1); // messageYjsSyncStep2
  encoding.writeVarUint8Array(e, Y.encodeStateAsUpdate(peerDoc));
  return { update: Buffer.from(encoding.toUint8Array(e)).toString("base64") };
}

const FIELDS = `
  <collaborative-field name="status" tier="lww">
    <select><option value=""></option><option value="active">active</option><option value="done">done</option></select>
  </collaborative-field>
  <collaborative-field name="urgent" tier="lww"><input type="checkbox"></collaborative-field>
  <collaborative-field name="description" tier="text"><textarea></textarea></collaborative-field>
`;

// Build a connected <collaborative-form> with the standard field set and a
// fake consumer, torn down with the test.
function makeForm(t, { name = "Ada", color = "#112233" } = {}) {
  const consumer = fakeConsumer();
  const form = document.createElement("collaborative-form");
  form.consumer = consumer;
  form.setAttribute("channel", "FormFieldsChannel");
  form.setAttribute("sgid", `token-${name}`);
  form.setAttribute("doc-key", "ticket-1-fields");
  form.setAttribute("name", name);
  form.setAttribute("color", color);
  form.innerHTML = FIELDS;
  document.body.appendChild(form);
  t.after(() => form.remove());
  const control = (fieldName) =>
    form.querySelector(`collaborative-field[name="${fieldName}"]`).querySelector("input, textarea, select");
  const field = (fieldName) => form.querySelector(`collaborative-field[name="${fieldName}"]`);
  const fire = (el, type) => el.dispatchEvent(new dom.window.Event(type, { bubbles: true }));
  return { form, consumer, control, field, fire };
}

// Relay doc updates between two forms, as the channel would. flush() applies
// everything queued since the last flush, so a test can hold updates back to
// create real concurrency.
function bridge(a, b) {
  const queues = [[], []];
  a.form.doc.on("update", (u) => queues[0].push(u));
  b.form.doc.on("update", (u) => queues[1].push(u));
  const flush = () => {
    for (const u of queues[0].splice(0)) Y.applyUpdate(b.form.doc, u, "wire");
    for (const u of queues[1].splice(0)) Y.applyUpdate(a.form.doc, u, "wire");
  };
  flush.auto = () => {
    a.form.doc.on("update", () => flush());
    b.form.doc.on("update", () => flush());
    flush();
  };
  return flush;
}

// Relay awareness state between two forms (the transport does this in
// production; here it's driven by hand).
function syncAwareness(from, to) {
  const awareness = from.form.awareness;
  applyAwarenessUpdate(to.form.awareness, encodeAwarenessUpdate(awareness, [awareness.clientID]), "test");
}

test("the form builds its provider from the attributes", (t) => {
  const { form, consumer } = makeForm(t);

  assert.deepEqual(JSON.parse(consumer.subscription.identifier), {
    channel: "FormFieldsChannel",
    sgid: "token-Ada",
  });
  assert.equal(form.doc.guid, "ticket-1-fields");
  assert.deepEqual(form.awareness.getLocalState(), { name: "Ada", color: "#112233", field: null });
  assert.equal(form.getAttribute("status"), "connecting");
});

test("the form reflects the provider status, synced included", (t) => {
  const { form, consumer } = makeForm(t);
  consumer.deliverConnected();

  assert.equal(form.getAttribute("status"), "connected");

  consumer.deliverReceived(syncStep2Envelope(new Y.Doc()));

  assert.equal(form.getAttribute("status"), "synced");
  assert.equal(form.provider.synced, true);
});

test("an lww field converges through the shared map", (t) => {
  const a = makeForm(t);
  const b = makeForm(t, { name: "Grace" });
  bridge(a, b).auto();

  a.control("status").value = "active";
  a.fire(a.control("status"), "change");

  assert.equal(b.control("status").value, "active");

  b.control("status").value = "done";
  b.fire(b.control("status"), "change");

  assert.equal(a.control("status").value, "done", "last write wins");
  assert.equal(a.form.doc.getMap("fields").get("status"), "done");
});

test("a checkbox binds as a boolean", (t) => {
  const a = makeForm(t);
  const b = makeForm(t, { name: "Grace" });
  bridge(a, b).auto();

  a.control("urgent").checked = true;
  a.fire(a.control("urgent"), "change");

  assert.equal(b.control("urgent").checked, true);
  assert.equal(b.form.doc.getMap("fields").get("urgent"), true, "stored as a boolean, cast server-side");
});

test("a text field merges concurrent typing", (t) => {
  const a = makeForm(t);
  const b = makeForm(t, { name: "Grace" });
  const flush = bridge(a, b);

  // Shared starting point.
  a.control("description").value = "hello";
  a.fire(a.control("description"), "input");
  flush();

  assert.equal(b.control("description").value, "hello");

  // Concurrent edits while the wire is held: a appends, b prepends.
  a.control("description").value = "hello!";
  a.fire(a.control("description"), "input");
  b.control("description").value = "Oi hello";
  b.fire(b.control("description"), "input");
  flush();
  flush(); // second pass so each side's merge reaches the other

  assert.equal(a.control("description").value, b.control("description").value, "both converge");
  assert.equal(a.control("description").value, "Oi hello!");
});

test("a remote splice keeps the local caret in place", (t) => {
  const a = makeForm(t);
  const b = makeForm(t, { name: "Grace" });
  const flush = bridge(a, b);

  a.control("description").value = "world";
  a.fire(a.control("description"), "input");
  flush();

  const textarea = a.control("description");
  textarea.focus();
  textarea.setSelectionRange(5, 5); // caret at the end

  b.control("description").value = "Oi world";
  b.fire(b.control("description"), "input");
  flush();

  assert.equal(textarea.value, "Oi world");
  assert.equal(textarea.selectionStart, 8, "caret shifted past the remote prepend");
});

test("a remote peer focusing the field shows an outline and a name chip", (t) => {
  const a = makeForm(t);
  const b = makeForm(t, { name: "Grace", color: "#445566" });

  b.fire(b.control("description"), "focusin");

  assert.equal(b.form.awareness.getLocalState().field, "description");

  syncAwareness(b, a);
  const field = a.field("description");

  assert.ok(field.hasAttribute("data-remote"));
  assert.equal(field.style.getPropertyValue("--collaborative-field-color"), "#445566");
  assert.equal(field.querySelector(".collaborative-field-chip").textContent, "Grace");
  assert.equal(a.field("status").hasAttribute("data-remote"), false, "only the focused field lights up");

  b.fire(b.control("description"), "focusout");
  syncAwareness(b, a);

  assert.equal(field.hasAttribute("data-remote"), false);
  assert.equal(field.querySelector(".collaborative-field-chip"), null);
});

test("local edits do not trip the local presence or clobber the control", (t) => {
  const a = makeForm(t);

  // A local change echoes through the map observer; the control must not be
  // rewritten (origin check), and no chip renders for ourselves.
  const select = a.control("status");
  select.value = "active";
  a.fire(select, "change");

  assert.equal(select.value, "active");
  a.fire(select, "focusin");

  assert.equal(a.field("status").hasAttribute("data-remote"), false, "own focus renders no remote outline");
});
