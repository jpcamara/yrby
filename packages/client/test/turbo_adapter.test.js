import { test } from "node:test";
import assert from "node:assert/strict";
import { registerDocumentMount, disconnectTurbo } from "../dist/turbo_adapter.js";

function mount(document, deactivate = () => {}) {
  return { ownerDocument: document, isConnected: true, activated: 0,
    activate() { this.activated++; }, deactivate };
}

test("an adapter registered by a teardown callback survives the old adapter", t => {
  const document = new EventTarget();
  t.after(() => disconnectTurbo(document));
  let replacement, deactivated = 0;
  const original = mount(document, () => {
    if (!replacement) {
      replacement = mount(document, () => { deactivated++; });
      registerDocumentMount(replacement);
    }
  });
  registerDocumentMount(original);
  disconnectTurbo(document);
  assert.equal(replacement.activated, 1);
  assert.equal(deactivated, 0);
  disconnectTurbo(document);
  assert.equal(deactivated, 1);
});

test("an adapter destroyed during cache cleanup does not schedule another reconciliation", t => {
  const document = new EventTarget();
  const originalSet = globalThis.setTimeout;
  let scheduled = 0;
  globalThis.setTimeout = () => { scheduled++; return 0; };
  t.after(() => { globalThis.setTimeout = originalSet; disconnectTurbo(document); });
  registerDocumentMount(mount(document, () => disconnectTurbo(document)));
  document.dispatchEvent(new Event("turbo:before-cache"));
  assert.equal(scheduled, 0);
});
