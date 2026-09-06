// Repeatable real-Chrome regression against the gem's actual signed channel.
// From the repository root: bundle install && bundle exec rake compile
// From packages/client: npm ci && npm run test:browser
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, open } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const assets = `${root}tmp/browser-assets`;
const port = process.env.PORT || "3789";
const base = `http://127.0.0.1:${port}`;
const ab = process.env.AB_BIN || "agent-browser";
const { stdout } = await exec(ab, ["session", "id", "--scope", "worktree", "--prefix", "yrby-element"], { cwd: root });
const session = stdout.trim();
const peer = `${session}-peer`;
await mkdir(assets, { recursive: true });
await build({ entryPoints: [fileURLToPath(new URL("client.js", import.meta.url))], bundle: true,
  splitting: true, format: "esm", outdir: assets });
const log = await open(`${root}tmp/browser-server.log`, "w");
const server = spawn("bundle", ["exec", "ruby", "-Ilib", "test/browser/app.rb"], {
  cwd: root, env: { ...process.env, PORT: port, BROWSER_ASSETS: assets,
    DATABASE_URL: `sqlite3:${root}tmp/browser-${port}.sqlite3` }, stdio: ["ignore", log.fd, log.fd],
});
server.on("error", error => console.error(error));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function browser(who, ...args) {
  const { stdout } = await exec(ab, ["--session", who, "--json", ...args], { timeout: 30000, maxBuffer: 2 ** 20 });
  const response = JSON.parse(stdout);
  if (!response.success) throw new Error(JSON.stringify(response.error));
  return response.data;
}
const evaluate = async (code, who = session) => (await browser(who, "eval", "-b", Buffer.from(code).toString("base64"))).result;
const wait = (condition, who = session) => browser(who, "wait", "--fn", condition);
const check = (label, value) => { assert.ok(value, label); console.log(`PASS ${label}`); };
async function state(name) {
  const response = await fetch(`${base}/state/${name}`);
  assert.equal(response.status, 200);
  return response.json();
}
try {
  let up = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(`Rails fixture exited ${server.exitCode}; see tmp/browser-server.log`);
    try { up = (await fetch(base)).ok; } catch {}
    if (up) break;
    await sleep(100);
  }
  assert.ok(up, "Rails fixture boots");
  await browser(session, "open", base);
  console.log(JSON.stringify(await browser(session, "snapshot", "-i")));
  await wait('document.querySelector("#body-doc")?.provider?.synced && document.querySelector("#secret-doc")?.provider?.synced');
  check("two simultaneous default elements share one real WebSocket", await evaluate('window.socketCount === 1 && document.querySelector("#body-doc").provider.consumer === document.querySelector("#secret-doc").provider.consumer'));
  check("readiness exists before import and resolves only after catch-up", await evaluate('initialReadiness.length === 2 && initialReadiness.every(Boolean) && browserEvents.length === 2 && browserEvents.every(e => e.synced && e.hasProvider)'));
  await browser(session, "find", "label", "Body", "fill", "before move");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("ordinary edit reaches the Ruby accessor", (await state("body")).text === "before move");
  await evaluate('window.savedDoc = document.querySelector("#body-doc").doc; window.savedProvider = document.querySelector("#body-doc").provider; document.querySelector("#move-target").append(document.querySelector("#body-doc"))');
  check("same-turn DOM move preserves identity and presence", await evaluate('document.querySelector("#body-doc").doc === savedDoc && document.querySelector("#body-doc").provider === savedProvider && savedProvider.awareness.getLocalState().user.name === "Browser reviewer"'));
  await evaluate('window.moved = document.querySelector("#body-doc"); moved.remove()');
  await wait('moved.provider.status === "disconnected"');
  await evaluate('document.querySelector("#move-target").append(moved)');
  await wait('moved.provider.synced');
  check("delayed reinsertion restores presence", await evaluate('moved.provider === savedProvider && moved.provider.awareness.getLocalState().user.name === "Browser reviewer"'));
  await browser(session, "find", "label", "Encrypted text", "fill", "encrypted browser edit");
  await wait('!document.querySelector("#secret-doc").provider.hasPending');
  const encrypted = await state("secret");
  check("encrypted browser edit reads through declared storage", encrypted.text === "encrypted browser edit" && encrypted.storage === "Y::EncryptedDocument");
  check("encrypted payload has a ciphertext envelope", JSON.parse(Buffer.from(encrypted.raw_payload, "base64").toString()).p !== undefined);

  // Close the actual WebSocket while leaving HTTP available for Turbo Drive.
  await evaluate('savedProvider.consumer.disconnect()');
  await wait('!savedProvider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  check("edit is pending and absent from storage before navigating", await evaluate('savedProvider.hasPending') && (await state("body")).text === "before move");
  await browser(session, "find", "role", "link", "click", "--name", "Away");
  await browser(session, "wait", "--url", "**/away");
  check("Turbo navigation stays in the same JS context", await evaluate('!!window.savedDoc'));
  await wait("savedDoc.isDestroyed");
  check("old snapshot document is disposed", await evaluate('savedDoc.isDestroyed'));
  await browser(session, "back");
  await wait('document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("actual Turbo history restore retains and acknowledges the unsent edit", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"') && (await state("body")).text === "pending across Turbo");
  await browser(peer, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced', peer);
  check("a fresh browser reads the recovered edit from the server", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"', peer));
  await browser(session, "screenshot", `${root}tmp/element-browser.png`);

  // An advance visit first renders the cached preview, then replaces it with
  // fresh server HTML. Hold that response so the transient page is observable.
  await evaluate('window.beforePreview = document.querySelector("#body-doc"); window.outgoingPreviewDoc = beforePreview.doc; window.outgoingPreviewProvider = beforePreview.provider; window.previewConsumer = beforePreview.provider.consumer; previewConsumer.disconnect(); window.connectionOpen = previewConsumer.connection.open; previewConsumer.connection.open = () => false');
  await wait('!beforePreview.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending before preview");
  check("preview regression starts with an unacknowledged edit", await evaluate('beforePreview.provider.hasPending'));
  await browser(session, "find", "role", "link", "click", "--name", "Away");
  await browser(session, "wait", "--url", "**/away");
  await evaluate(`window.originalFetch = window.fetch;
    window.fetch = (...args) => new URL(args[0].url || args[0], location.href).pathname === "/"
      ? new Promise(resolve => { window.releaseFresh = () => resolve(originalFetch(...args)); })
      : originalFetch(...args);
    Turbo.visit("/");`);
  await wait('document.documentElement.hasAttribute("data-turbo-preview") && !!document.querySelector("#body-doc") && !!window.releaseFresh');
  check("actual Turbo preview is inert and never starts a provider", await evaluate(`window.previewElement = document.querySelector("#body-doc");
    window.previewDoc = previewElement.doc;
    previewElement.querySelector("textarea").focus();
    previewElement.inert && !previewElement.provider && document.activeElement !== previewElement.querySelector("textarea")`));
  check("outgoing delivery survives while the preview is offline", await evaluate('outgoingPreviewProvider.hasPending && !outgoingPreviewDoc.isDestroyed'));
  await evaluate('previewConsumer.connection.open = connectionOpen; previewConsumer.connection.open(); releaseFresh(); window.fetch = originalFetch');
  await wait('!document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("fresh response releases the transient preview document", await evaluate('previewDoc.isDestroyed && previewElement.provider === undefined && document.querySelector("#body-doc") !== previewElement'));
  await wait('outgoingPreviewDoc.isDestroyed && !outgoingPreviewProvider.hasPending && document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"');
  check("fresh page has a newly minted grant", await evaluate('beforePreview.getAttribute("grant") !== document.querySelector("#body-doc").getAttribute("grant")'));
  check("fresh HTML receives and acknowledges the pre-preview pending edit", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"') && (await state("body")).text === "pending before preview");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!document.querySelector("#body-doc").provider.hasPending');

  // Exercise Turbo's real morph algorithm while preserving the element node.
  await evaluate(`window.morphElement = document.querySelector("#body-doc");
    window.morphProvider = morphElement.provider;
    window.originalGrant = morphElement.getAttribute("grant");
    window.identityErrors = [];
    morphElement.addEventListener("yrby:error", event => identityErrors.push(event.detail.error.message));
    morphProvider.consumer.disconnect();`);
  await wait('!morphProvider.synced');
  await browser(session, "find", "label", "Body", "fill", "private body pending");
  await evaluate(`const replacement = morphElement.cloneNode(true);
    replacement.setAttribute("grant", document.querySelector("#secret-doc").getAttribute("grant"));
    replacement.setAttribute("name", "secret");
    Turbo.renderStreamMessage('<turbo-stream action="replace" method="morph" target="body-doc"><template>' + replacement.outerHTML + '</template></turbo-stream>');`);
  await wait('document.querySelector("#body-doc").getAttribute("name") === "secret"');
  check("Turbo morph cannot retarget a live provider", await evaluate('document.querySelector("#body-doc") === morphElement && morphElement.provider === morphProvider && morphProvider.status === "disconnected" && morphProvider.hasPending && identityErrors.length > 0'));
  await evaluate(`document.dispatchEvent(new Event("turbo:before-cache"));
    window.morphedSnapshot = morphElement.getAttribute("data-yrby-snapshot");
    window.retargeted = document.createElement("yrby-document");
    retargeted.setAttribute("grant", morphElement.getAttribute("grant"));
    retargeted.setAttribute("name", "secret");
    retargeted.setAttribute("data-yrby-snapshot", morphedSnapshot);
    document.body.append(retargeted);`);
  await wait('retargeted.provider?.synced && !retargeted.provider.hasPending');
  check("morphed cache retains the original identity and cannot leak its tail", await evaluate('JSON.parse(morphedSnapshot).identity === JSON.stringify(["Y::DocumentChannel", originalGrant, "body"]) && retargeted.doc.getText("content").toString() === "encrypted browser edit"') && (await state("secret")).text === "encrypted browser edit");
  await evaluate('retargeted.remove(); retargeted.destroy(); morphElement.setAttribute("grant", originalGrant); morphElement.setAttribute("name", "body")');
  await wait('morphProvider.synced && !morphProvider.hasPending');
  check("reverting the identity preserves delivery to the original document", (await state("body")).text === "private body pending");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!morphProvider.hasPending');

  await browser(session, "open", `${base}/?detach=1`);
  await wait('document.querySelector("#secret-doc")?.provider?.synced');
  check("removal during the real dynamic import does not subscribe", await evaluate('!!window.detachedElement && detachedElement.provider === undefined'));
  await evaluate('document.body.append(detachedElement)');
  await wait('detachedElement.provider?.synced');
  check("reinsert after async cancellation subscribes successfully", await evaluate('detachedElement.doc.getText("content").toString() === "pending across Turbo"'));
  const errors = await browser(session, "errors");
  check("no browser exceptions", (errors.errors ?? []).length === 0);
  console.log("PASS element browser regression (real Rails, ActionCable, Turbo and agent-browser)");
} finally {
  for (const who of [session, peer]) await browser(who, "close").catch(() => {});
  server.kill("SIGTERM");
  await log.close();
}
