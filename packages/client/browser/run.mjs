// Regression test in real Chrome against the gem's signed channel.
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
// We name the sessions ourselves. agent-browser's `session` command only prints
// the current name, and an unknown subcommand falls through to it and prints
// "default", which shares a browser with everything else on the default session.
// A per-process name keeps parallel worktrees apart.
const session = process.env.AB_SESSION || `yrby-element-${process.pid}`;
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
  await wait('["#body-doc", "#secret-doc", "#notes-doc"].every(id => document.querySelector(id)?.provider?.synced)');
  check("elements on the default consumer share one WebSocket", await evaluate('window.socketCount === 1 && document.querySelector("#body-doc").provider.consumer === document.querySelector("#secret-doc").provider.consumer'));
  // Three elements on the page: body, secret, and notes.
  check("whenSynced exists before the import and resolves after catch-up", await evaluate('initialReadiness.length === 3 && initialReadiness.every(Boolean) && browserEvents.length === 3 && browserEvents.every(e => e.synced && e.hasProvider)'));
  await browser(session, "find", "label", "Body", "fill", "before move");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("an edit reaches the Ruby accessor", (await state("body")).text === "before move");
  await evaluate('window.savedDoc = document.querySelector("#body-doc").doc; window.savedProvider = document.querySelector("#body-doc").provider; document.querySelector("#move-target").append(document.querySelector("#body-doc"))');
  check("moving the element in the same turn keeps its document and editor binding", await evaluate('document.querySelector("#body-doc").doc === savedDoc && document.querySelector("#body-doc").provider === savedProvider && document.querySelector("#body-doc").mountCount === 1'));
  await evaluate('window.moved = document.querySelector("#body-doc"); moved.remove()');
  await wait('moved.provider === undefined && savedDoc.isDestroyed');
  await evaluate('document.querySelector("#move-target").append(moved)');
  await wait('moved.provider.synced');
  check("reinserting it later gives a new provider with the saved content", await evaluate('moved.provider !== savedProvider && moved.doc.getText("content").toString() === "before move"'));
  // ActionCable reopens its socket whenever a subscription is created, so
  // goOffline stubs the connection's open() as well as calling disconnect().
  await evaluate(`window.savedDoc = moved.doc; window.savedProvider = moved.provider; window.cable = savedProvider.consumer;
    window.cableOpen = cable.connection.open;
    window.goOffline = () => { cable.connection.open = () => false; cable.disconnect(); };
    window.goOnline = () => { cable.connection.open = cableOpen; cable.connect(); };`);
  await browser(session, "find", "label", "Encrypted text", "fill", "encrypted browser edit");
  await wait('!document.querySelector("#secret-doc").provider.hasPending');
  const encrypted = await state("secret");
  check("an encrypted edit reads back through the declared storage", encrypted.text === "encrypted browser edit" && encrypted.storage === "Y::EncryptedDocument");
  check("encrypted payload has a ciphertext envelope", JSON.parse(Buffer.from(encrypted.raw_payload, "base64").toString()).p !== undefined);

  // Take the cable down and keep HTTP up for Turbo Drive.
  await evaluate('goOffline(); window.suspendedSockets = socketCount');
  await wait('!savedProvider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  check("the edit is pending and unsaved before navigating", await evaluate('savedProvider.hasPending') && (await state("body")).text === "before move");
  // Find the link by its text. agent-browser 0.28's role lookup finds buttons
  // but misses links and headings.
  await browser(session, "find", "text", "Away", "click");
  // wait --url hangs in agent-browser 0.28 even when the URL already matches,
  // so check location with a --fn wait.
  await wait("location.pathname === '/away'");
  check("Turbo navigation stays in the same JS context", await evaluate('!!window.savedDoc'));
  check("the pending session stays open after its page goes away", await evaluate('!savedDoc.isDestroyed && savedProvider.hasPending && socketCount === suspendedSockets'));
  await browser(session, "back");
  await wait('document.querySelector("#body-doc")?.doc === savedDoc');
  check("going back while offline reuses the pending session and socket", await evaluate('socketCount === suspendedSockets && document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"'));
  await evaluate('goOnline()');
  await wait('document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("going back keeps the unsent edit and delivers it", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"') && (await state("body")).text === "pending across Turbo");
  // Close the WebSocket under the consumer, then reopen it.
  await evaluate(`window.networkSession = document.querySelector("#body-doc").session;
    window.networkConnection = networkSession.provider.consumer.connection;
    window.networkOpen = networkConnection.open; networkConnection.open = () => false;
    networkConnection.webSocket.close();`);
  await wait('!networkSession.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "network drop recovered");
  await browser(session, "find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
  check("after a socket drop the detached session stays open with its pending edit", await evaluate('networkSession.state === "open" && networkSession.hasPending'));
  await browser(session, "back");
  await wait('document.querySelector("#body-doc")?.session === networkSession');
  await evaluate('networkConnection.open = networkOpen; networkConnection.open()');
  await wait('networkSession.provider.synced && !networkSession.hasPending');
  check("reconnecting the socket delivers the offline edit", (await state("body")).text === "network drop recovered");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!networkSession.hasPending');
  await browser(peer, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced', peer);
  check("a second browser reads the recovered edit from the server", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"', peer));
  await browser(session, "screenshot", `${root}tmp/element-browser.png`);

  // An advance visit renders the cached preview first, then the server's HTML.
  // Hold the server response so the test can inspect the preview.
  await evaluate('window.beforePreview = document.querySelector("#body-doc"); window.outgoingPreviewDoc = beforePreview.doc; window.outgoingPreviewProvider = beforePreview.provider; goOffline()');
  await wait('!beforePreview.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending before preview");
  check("the preview test starts with an unacknowledged edit", await evaluate('beforePreview.provider.hasPending'));
  await browser(session, "find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
  await evaluate(`window.originalFetch = window.fetch;
    window.fetch = (...args) => new URL(args[0].url || args[0], location.href).pathname === "/"
      ? new Promise(resolve => { window.releaseFresh = () => resolve(originalFetch(...args)); })
      : originalFetch(...args);
    Turbo.visit("/");`);
  await wait('document.documentElement.hasAttribute("data-turbo-preview") && !!document.querySelector("#body-doc") && !!window.releaseFresh');
  check("the Turbo preview is inert with no provider and an unfocusable textarea", await evaluate(`window.previewElement = document.querySelector("#body-doc");
    window.previewDoc = previewElement.doc;
    previewElement.querySelector("textarea").focus();
    previewElement.inert && !previewElement.provider && document.activeElement !== previewElement.querySelector("textarea")`));
  check("the outgoing session keeps its pending edit during an offline preview", await evaluate('outgoingPreviewProvider.hasPending && !outgoingPreviewDoc.isDestroyed'));
  await evaluate('releaseFresh(); window.fetch = originalFetch');
  await wait('!document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector("#body-doc") !== previewElement');
  check("the new page stays inert while the cable is down", await evaluate('document.querySelector("#body-doc").inert && !document.querySelector("#body-doc").provider.synced'));
  await evaluate('goOnline()');
  await wait('!document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("the preview element has no document or provider", await evaluate('previewDoc === undefined && previewElement.doc === undefined && previewElement.provider === undefined'));
  await wait('outgoingPreviewDoc.isDestroyed && !outgoingPreviewProvider.hasPending && document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"');
  check("the new page has a different grant", await evaluate('beforePreview.getAttribute("grant") !== document.querySelector("#body-doc").getAttribute("grant")'));
  check("the edit made before the preview shows on the new page and reaches Ruby", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"') && (await state("body")).text === "pending before preview");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!document.querySelector("#body-doc").provider.hasPending');

  // Two editors on one grant share a queue, and each can be removed on its own.
  await evaluate(`window.primary = document.querySelector("#body-doc");
    window.secondView = primary.cloneNode(true); secondView.id = "second-view";
    secondView.querySelector("textarea").setAttribute("aria-label", "Second view");
    document.body.append(secondView);`);
  await wait('secondView.provider?.synced');
  check("two views share the document and delivery queue", await evaluate('primary.session === secondView.session && primary.provider === secondView.provider'));
  await browser(session, "find", "label", "Second view", "fill", "shared views");
  await wait('!secondView.provider.hasPending');
  await evaluate('secondView.remove()');
  await wait('secondView.provider === undefined');
  check("removing one view leaves the other bound", await evaluate('primary.provider.synced && primary.doc.getText("content").toString() === "shared views" && secondView.unmountCount === 1'));

  // A morph rebinds the element while the old session sends its queue under the old grant.
  await evaluate(`window.morphElement = primary;
    window.morphSession = primary.session; window.originalGrant = primary.getAttribute("grant");
    window.mountsBeforeMorph = primary.mountCount;
    goOffline();`);
  await browser(session, "find", "label", "Body", "fill", "private body pending");
  await evaluate(`const replacement = morphElement.cloneNode(true);
    replacement.setAttribute("grant", document.querySelector("#secret-doc").getAttribute("grant"));
    replacement.setAttribute("name", "secret");
    Turbo.renderStreamMessage('<turbo-stream action="replace" method="morph" target="body-doc"><template>' + replacement.outerHTML + '</template></turbo-stream>');`);
  await wait('document.querySelector("#body-doc").getAttribute("name") === "secret" && morphElement.session !== morphSession');
  check("a Turbo morph switches leases and keeps the original pending queue", await evaluate('document.querySelector("#body-doc") === morphElement && morphSession.hasPending && morphSession.descriptor.grant === originalGrant && morphElement.session === document.querySelector("#secret-doc").session && morphElement.mountCount === mountsBeforeMorph + 1'));
  await evaluate('goOnline()');
  await wait('morphSession.state === "closed" && morphElement.provider.synced');
  check("the pending edit reaches only the original Ruby document", (await state("body")).text === "private body pending" && (await state("secret")).text === "encrypted browser edit");
  await evaluate('morphElement.setAttribute("grant", originalGrant); morphElement.setAttribute("name", "body")');
  await wait('morphElement.provider?.synced && morphElement.doc.getText("content").toString() === "private body pending"');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!morphElement.provider.hasPending');

  // Retarget while detached, then reinsert in the same turn. The old queue
  // should still go to the original document after the element names another.
  await evaluate(`window.moveSession = morphElement.session;
    window.moveMounts = morphElement.mountCount;
    goOffline();`);
  await wait('!moveSession.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending through detached retarget");
  await evaluate(`const parent = morphElement.parentNode;
    morphElement.remove();
    morphElement.setAttribute("grant", document.querySelector("#secret-doc").getAttribute("grant"));
    morphElement.setAttribute("name", "secret");
    parent.append(morphElement);`);
  await wait('morphElement.session === document.querySelector("#secret-doc").session');
  check("retargeting while detached replaces the editor and keeps the pending queue", await evaluate(
    'morphElement.session !== moveSession && moveSession.hasPending && morphElement.mountCount === moveMounts + 1 && morphElement.doc.getText("content").toString() === "encrypted browser edit"'));
  await evaluate('goOnline()');
  await wait('moveSession.state === "closed" && morphElement.provider.synced');
  check("retargeting while detached sends the pending text only to the original document",
    (await state("body")).text === "pending through detached retarget" && (await state("secret")).text === "encrypted browser edit");
  await evaluate('morphElement.setAttribute("grant", originalGrant); morphElement.setAttribute("name", "body")');
  await wait('morphElement.provider?.synced && morphElement.doc.getText("content").toString() === "pending through detached retarget"');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!morphElement.provider.hasPending');

  // A canceled visit fires before-cache and keeps the current page.
  await evaluate('window.beforeCancelMounts = morphElement.mountCount; document.dispatchEvent(new Event("turbo:before-cache"))');
  await wait('morphElement.provider?.synced && morphElement.mountCount === beforeCancelMounts + 1');
  check("a canceled visit rebinds the editor once", await evaluate('morphElement.doc.getText("content").toString() === "pending across Turbo" && !morphElement.inert'));

  // Permanent DOM nodes get a new editor binding after navigation.
  await evaluate('morphElement.setAttribute("data-turbo-permanent", ""); window.permanentMounts = morphElement.mountCount; Turbo.visit("/?permanent=1")');
  await wait('location.search === "?permanent=1" && document.querySelector("#body-doc")?.provider?.synced');
  check("a Turbo permanent element ends up with one editor binding", await evaluate('document.querySelector("#body-doc") === morphElement && morphElement.mountCount > permanentMounts && morphElement.mountCount - morphElement.unmountCount === 1'));

  await browser(session, "open", `${base}/?detach=1`);
  await wait('document.querySelector("#secret-doc")?.provider?.synced');
  check("an element removed during the dynamic import stays unsubscribed", await evaluate('!!window.detachedElement && detachedElement.provider === undefined'));
  await evaluate('document.body.append(detachedElement)');
  await wait('detachedElement.provider?.synced');
  check("reinserting it after the canceled import subscribes", await evaluate('detachedElement.doc.getText("content").toString() === "pending across Turbo"'));
  // Save a Rails subscription's callbacks, then replace the subscription.
  await evaluate(`window.guardSession = detachedElement.session;
    window.guardProvider = guardSession.provider;
    window.oldGuardSubscription = guardProvider.consumer.subscriptions.subscriptions.find(sub =>
      sub.identifier === JSON.stringify({ channel: guardProvider.channelName, ...guardProvider.channelParams }));
    guardProvider.disconnect();`);
  await wait('guardProvider.status === "disconnected"');
  await evaluate('guardProvider.connect()');
  await wait('guardProvider.synced');
  check("callbacks from an old subscription are ignored after a reconnect",
    await evaluate(`oldGuardSubscription.disconnected(); oldGuardSubscription.rejected();
      guardSession.state === "open" && guardSession.provider === guardProvider && guardProvider.synced`));
  await browser(session, "find", "label", "Body", "fill", "guarded reconnect edit");
  await wait('!guardSession.hasPending');
  check("typing after the old callbacks fire reaches Ruby through the new subscription", (await state("body")).text === "guarded reconnect edit");
  // The managed subscription nonce works with the AnyCable web client.
  await evaluate(`(async () => { window.anyConsumer = await anyCableConsumer();
    YrbyDocumentElement.consumer = anyConsumer;
    window.anyElement = document.querySelector("#body-doc").cloneNode(true);
    anyElement.id = "any-document";
    anyElement.querySelector("textarea").setAttribute("aria-label", "AnyCable body");
    document.body.append(anyElement); })()`);
  await wait('anyElement.provider?.synced');
  await browser(session, "find", "label", "AnyCable body", "fill", "AnyCable session edit");
  await wait('!anyElement.provider.hasPending');
  check("AnyCable client persists and acknowledges a managed session", (await state("body")).text === "AnyCable session edit");
  await evaluate('window.oldAnyRoute = anyElement.provider.channelParams.session_id; window.oldAnyDoc = anyElement.doc; anyElement.remove()');
  await wait('oldAnyDoc.isDestroyed');
  await evaluate('document.body.append(anyElement)');
  await wait('anyElement.provider?.synced');
  check("a reinserted AnyCable element uses a new ack route and loads the saved content", await evaluate('anyElement.provider.channelParams.session_id !== oldAnyRoute && anyElement.doc.getText("content").toString() === "AnyCable session edit"'));
  await evaluate('anyElement.remove(); anyConsumer.disconnect(); YrbyDocumentElement.consumer = undefined');

  // A grant that expires while the socket is open gets refreshed on reconnect.
  // The notes grant lasts two seconds. Let it expire and drop the socket so
  // Action Cable resubscribes with the expired grant. The element should fetch
  // a new grant from /grant and keep the same session.
  await browser(session, "open", base);
  await wait('document.querySelector("#notes-doc")?.provider?.synced');
  await evaluate(`window.notesSession = document.querySelector("#notes-doc").session; window.notesDoc = notesSession.doc;
    window.refreshCalls = 0; const realFetch = window.fetch;
    window.fetch = (...args) => { if (String(args[0]).includes("/grant")) window.refreshCalls++; return realFetch(...args); };`);
  await browser(session, "wait", "3000");
  await evaluate('notesSession.provider.consumer.connection.webSocket.close()');
  await wait('window.refreshCalls >= 1 && notesSession.state !== "blocked" && notesSession.provider?.synced');
  await browser(session, "find", "label", "Notes", "fill", "after grant refresh");
  await wait('!notesSession.provider.hasPending');
  check("reconnecting with an expired grant fetches a new one and keeps the session",
    (await state("notes")).text === "after grant refresh" && await evaluate('notesSession.doc === notesDoc && refreshCalls === 1'));

  // A valid grant is still checked against the connection's policy for the signed-in user.
  await browser(peer, "open", `${base}/?user=visitor`);
  await wait('documentErrors.some(event => event.id === "body-doc" && event.session?.state === "blocked")', peer);
  check("a valid grant is rejected for a user without edit permission", await evaluate(
    'document.querySelector("#body-doc").mountCount === undefined && document.querySelector("#body-doc").querySelector("textarea").disabled', peer));
  await wait('document.querySelector("#secret-doc")?.provider?.synced', peer);

  // The policy runs when a client subscribes, so revoking permission affects the
  // next subscription. An open one keeps working.
  await browser(session, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced && document.querySelector("#secret-doc")?.provider?.synced');
  await evaluate('window.beforeDenialSockets = socketCount');
  const permission = await fetch(`${base}/permission?editor=nobody`, { method: "POST" });
  assert.equal(permission.status, 204);
  await browser(session, "find", "label", "Body", "fill", "edited after permission revoked");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("an open subscription keeps working after permission is revoked",
    (await state("body")).text === "edited after permission revoked");
  await browser(session, "find", "label", "Encrypted text", "fill", "other subscription still works");
  await wait('!document.querySelector("#secret-doc").provider.hasPending');
  check("other subscriptions on the socket keep working after revocation", (await state("secret")).text === "other subscription still works" &&
    await evaluate('socketCount === beforeDenialSockets'));

  // Reloading resubscribes, and the revocation applies there.
  await browser(session, "open", base);
  await wait('documentErrors.some(event => event.id === "body-doc" && event.session?.state === "blocked")');
  check("the next subscription is refused after revocation", await evaluate(
    'document.querySelector("#body-doc").querySelector("textarea").disabled'));

  // An authorized peer can still edit. Restoring permission lets this user back in.
  const restore = await fetch(`${base}/permission?editor=editor`, { method: "POST" });
  assert.equal(restore.status, 204);
  await browser(peer, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced', peer);
  await browser(peer, "find", "label", "Body", "fill", "peer edit after revocation");
  await wait('!document.querySelector("#body-doc").provider.hasPending', peer);
  check("an authorized peer can still edit", (await state("body")).text === "peer edit after revocation");
  await browser(session, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced');
  check("restoring permission admits the user on the next subscription", await evaluate(
    'document.querySelector("#body-doc").doc.getText("content").toString() === "peer edit after revocation"'));
  const errors = await browser(session, "errors");
  check("no browser exceptions", (errors.errors ?? []).length === 0);
  console.log("PASS element browser regression (real Rails, ActionCable, Turbo and agent-browser)");
} finally {
  for (const who of [session, peer]) await browser(who, "close").catch(() => {});
  server.kill("SIGTERM");
  await log.close();
}
