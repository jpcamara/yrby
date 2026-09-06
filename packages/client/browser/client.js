import * as Turbo from "@hotwired/turbo";
import { YrbyDocumentElement } from "../src/document_element.ts";
window.Turbo = Turbo;
window.YrbyDocumentElement = YrbyDocumentElement;
window.browserEvents = [];
window.initialReadiness = [];
for (const el of document.querySelectorAll("yrby-document")) {
  const ready = el.whenSynced;
  window.initialReadiness.push(ready instanceof Promise);
  ready.then(() => window.browserEvents.push({ ready: true, hasProvider: !!el.provider, synced: el.provider.synced }));
}
document.addEventListener("yrby:synced", ({ target: el }) => {
  const input = el.querySelector("textarea");
  if (!input) return;
  const text = el.doc.getText("content");
  const update = () => { input.value = text.toString(); };
  update();
  input.disabled = false;
  input.oninput = () => el.doc.transact(() => {
    text.delete(0, text.length);
    text.insert(0, input.value);
  });
  text.observe(update);
  el.provider.awareness.setLocalState({ user: { name: "Browser reviewer" } });
  document.querySelector("#status").textContent = "Synced";
});
if (new URL(location.href).searchParams.has("detach")) {
  window.detachedElement = document.querySelector("#body-doc");
  window.detachedElement.remove();
}
