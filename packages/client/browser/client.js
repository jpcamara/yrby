import * as Turbo from "@hotwired/turbo";
import { YrbyDocumentElement } from "../src/document_element.ts";
window.anyCableConsumer = async () => (await import("@anycable/web")).createConsumer("/cable");
window.Turbo = Turbo;
window.YrbyDocumentElement = YrbyDocumentElement;
window.browserEvents = [];
window.documentErrors = [];
document.addEventListener("yrby:error", ({ target, detail }) => {
  window.documentErrors.push({ id: target.id, ...detail });
});
window.initialReadiness = [];
for (const el of document.querySelectorAll("yrby-document")) {
  const ready = el.whenSynced;
  window.initialReadiness.push(ready instanceof Promise);
  ready.then(() => window.browserEvents.push({ ready: true, hasProvider: !!el.provider, synced: el.provider.synced }));
}
document.addEventListener("yrby:synced", ({ target: el, detail: { doc, signal, attachment } }) => {
  const input = el.querySelector("textarea");
  if (!input) return;
  el.mountCount = (el.mountCount || 0) + 1;
  const text = doc.getText("content");
  const update = () => { input.value = text.toString(); };
  update();
  input.disabled = false;
  input.addEventListener("input", () => doc.transact(() => {
    text.delete(0, text.length);
    text.insert(0, input.value);
  }), { signal });
  text.observe(update);
  const presence = () => attachment.setPresence({ user: { name: "Browser reviewer" } });
  input.addEventListener("focus", presence, { signal });
  input.addEventListener("blur", () => attachment.setPresence(null), { signal });
  presence();
  signal.addEventListener("abort", () => {
    el.unmountCount = (el.unmountCount || 0) + 1;
    text.unobserve(update);
    input.disabled = true;
  }, { once: true });
  document.querySelector("#status").textContent = "Synced";
});
if (new URL(location.href).searchParams.has("detach")) {
  window.detachedElement = document.querySelector("#body-doc");
  window.detachedElement.remove();
}
