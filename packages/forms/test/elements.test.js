import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import * as Y from "yjs";
import * as encoding from "lib0/encoding";
import { encodeAwarenessUpdate, applyAwarenessUpdate } from "y-protocols/awareness";

// The elements need a DOM, and jsdom provides it. The globals must be in
// place before the packages are imported, because importing registers the
// elements and yrby-client's session store extends EventTarget.
const dom = new JSDOM("<!doctype html><html><body></body></html>");
for (const key of [
  "window",
  "document",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "HTMLSelectElement",
  "customElements",
  "CustomEvent",
  "Event",
  "EventTarget",
  "FocusEvent",
  "Node",
]) {
  globalThis[key] = dom.window[key];
}
await import("../dist/index.js");
const { DocumentSessionStore, MessageType } = await import("yrby-client");
const { YrbyDocumentElement } = await import("yrby-client/element");

const tick = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve();
};

// A fake Action Cable consumer with no transport. A test delivers frames by
// hand through the subscription's handlers.
const consumer = {
  created: [],
  subscriptions: {
    create(params, handlers) {
      const subscription = { params, handlers, sent: [], send: (data) => subscription.sent.push(data), unsubscribe() {} };
      consumer.created.push(subscription);
      return subscription;
    },
  },
};
YrbyDocumentElement.consumer = consumer;

// What the server sends once it is subscribed: the document's full state.
function deliverSync(subscription, serverDoc = new Y.Doc()) {
  subscription.handlers.connected();
  const e = encoding.createEncoder();
  encoding.writeVarUint(e, MessageType.Sync);
  encoding.writeVarUint(e, 1); // messageYjsSyncStep2
  encoding.writeVarUint8Array(e, Y.encodeStateAsUpdate(serverDoc));
  subscription.handlers.received({ update: Buffer.from(encoding.toUint8Array(e)).toString("base64") });
}

const FIELDS = `
  <collaborative-field name="status" tier="lww">
    <select><option value=""></option><option value="active">active</option><option value="done">done</option></select>
  </collaborative-field>
  <collaborative-field name="urgent" tier="lww"><input type="hidden" value="0"><input type="checkbox"></collaborative-field>
  <collaborative-field name="description" tier="text"><textarea></textarea></collaborative-field>
`;

// Adds a <yrby-document> holding the standard field set, as the form helper
// renders it. Each person gets their own grant, so each gets their own
// session and Y.Doc. `sync: false` leaves the document unsynced.
async function makeForm(t, { name = "Ada", color = "#112233", sync = true, serverDoc } = {}) {
  const form = document.createElement("yrby-document");
  form.setAttribute("channel", "Y::Forms::FieldsChannel");
  form.setAttribute("grant", `grant-${name}`);
  form.setAttribute("name", "fields");
  form.dataset.userName = name;
  form.dataset.userColor = color;
  form.innerHTML = FIELDS;
  document.body.appendChild(form);
  await tick();
  const subscription = consumer.created.at(-1);
  t.after(async () => {
    form.remove();
    await tick();
    for (const session of DocumentSessionStore.for(consumer).sessions) session.discard();
  });
  const control = (fieldName) =>
    form.querySelector(`collaborative-field[name="${fieldName}"]`).querySelector("input:not([type=hidden]), textarea, select");
  const field = (fieldName) => form.querySelector(`collaborative-field[name="${fieldName}"]`);
  const fire = (el, type) => el.dispatchEvent(new dom.window.Event(type, { bubbles: true }));
  const synced = async () => {
    deliverSync(subscription, serverDoc);
    await form.whenSynced;
  };
  if (sync) await synced();
  return { form, subscription, control, field, fire, synced };
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

// Relay presence from one form to another. The transport does this in
// production.
function syncAwareness(from, to) {
  const awareness = from.form.provider.awareness;
  applyAwarenessUpdate(to.form.provider.awareness, encodeAwarenessUpdate(awareness, [awareness.clientID]), "test");
}

test("the document subscribes to the channel the form helper names", async (t) => {
  const { channel, grant, name } = (await makeForm(t)).subscription.params;

  assert.deepEqual({ channel, grant, name }, { channel: "Y::Forms::FieldsChannel", grant: "grant-Ada", name: "fields" });
});

test("a field binds when the document syncs, and shows the stored values", async (t) => {
  const serverDoc = new Y.Doc();
  serverDoc.getMap("fields").set("status", "done");
  serverDoc.getMap("fields").set("urgent", true);
  serverDoc.getText("fields/description").insert(0, "Stored text");
  const a = await makeForm(t, { sync: false, serverDoc });

  a.control("status").value = "active";
  a.fire(a.control("status"), "change");

  assert.equal(a.form.doc.getMap("fields").get("status"), undefined, "nothing is bound before the first sync");

  await a.synced();

  assert.equal(a.control("status").value, "done");
  assert.equal(a.control("urgent").checked, true);
  assert.equal(a.control("description").value, "Stored text");
});

test("a field added after the document synced binds too", async (t) => {
  const a = await makeForm(t);
  a.form.doc.getMap("fields").set("priority", "7");

  a.form.insertAdjacentHTML("beforeend", `<collaborative-field name="priority" tier="lww"><input type="number"></collaborative-field>`);

  assert.equal(a.control("priority").value, "7");
});

test("a field stops writing when its lease ends, and binds again on the next sync", async (t) => {
  const a = await makeForm(t);
  const doc = a.form.doc;
  a.form.remove();
  await tick();

  a.control("status").value = "active";
  a.fire(a.control("status"), "change");

  assert.equal(doc.getMap("fields").get("status"), undefined);

  document.body.appendChild(a.form);
  await tick();
  deliverSync(consumer.created.at(-1));
  await a.form.whenSynced;
  a.fire(a.control("status"), "change");

  assert.equal(a.form.doc.getMap("fields").get("status"), "active");
});

test("an lww field converges through the shared map", async (t) => {
  const a = await makeForm(t);
  const b = await makeForm(t, { name: "Grace" });
  bridge(a, b).auto();

  a.control("status").value = "active";
  a.fire(a.control("status"), "change");

  assert.equal(b.control("status").value, "active");

  b.control("status").value = "done";
  b.fire(b.control("status"), "change");

  assert.equal(a.control("status").value, "done", "last write wins");
  assert.equal(a.form.doc.getMap("fields").get("status"), "done");
});

test("a checkbox binds as a boolean", async (t) => {
  const a = await makeForm(t);
  const b = await makeForm(t, { name: "Grace" });
  bridge(a, b).auto();

  a.control("urgent").checked = true;
  a.fire(a.control("urgent"), "change");

  assert.equal(b.control("urgent").checked, true);
  assert.equal(b.form.doc.getMap("fields").get("urgent"), true, "stored as a boolean, cast server-side");
});

test("a text field merges concurrent typing", async (t) => {
  const a = await makeForm(t);
  const b = await makeForm(t, { name: "Grace" });
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

test("a remote splice keeps the local caret in place", async (t) => {
  const a = await makeForm(t);
  const b = await makeForm(t, { name: "Grace" });
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

test("a remote peer focusing the field shows an outline and a name chip", async (t) => {
  const a = await makeForm(t);
  const b = await makeForm(t, { name: "Grace", color: "#445566" });

  b.fire(b.control("description"), "focusin");

  assert.deepEqual(b.form.provider.awareness.getLocalState(), {
    user: { name: "Grace", color: "#445566" },
    field: "description",
  });

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

test("local edits do not trip the local presence or clobber the control", async (t) => {
  const a = await makeForm(t);

  // A local change echoes through the map observer; the control must not be
  // rewritten (origin check), and no chip renders for ourselves.
  const select = a.control("status");
  select.value = "active";
  a.fire(select, "change");

  assert.equal(select.value, "active");
  a.fire(select, "focusin");

  assert.equal(a.field("status").hasAttribute("data-remote"), false, "own focus renders no remote outline");
});
