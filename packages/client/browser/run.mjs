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
// Name the sessions here instead of asking agent-browser for one. Its `session`
// command only prints the current name, and an unknown subcommand falls through
// to it and prints "default", which would share a browser with anything else on
// the default session. A per-process name keeps this run isolated and keeps
// parallel worktrees from colliding.
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
  await wait('["#body-doc", "#secret-doc", "#external-doc", "#notes-doc"].every(id => document.querySelector(id)?.provider?.synced)');
  check("simultaneous default elements share one real WebSocket", await evaluate('window.socketCount === 1 && document.querySelector("#body-doc").provider.consumer === document.querySelector("#secret-doc").provider.consumer'));
  // Four elements on the page: body, secret, external, and notes.
  check("readiness exists before import and resolves only after catch-up", await evaluate('initialReadiness.length === 4 && initialReadiness.every(Boolean) && browserEvents.length === 4 && browserEvents.every(e => e.synced && e.hasProvider)'));
  await browser(session, "find", "label", "Body", "fill", "before move");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("ordinary edit reaches the Ruby accessor", (await state("body")).text === "before move");
  await evaluate('window.savedDoc = document.querySelector("#body-doc").doc; window.savedProvider = document.querySelector("#body-doc").provider; document.querySelector("#move-target").append(document.querySelector("#body-doc"))');
  check("same-turn DOM move preserves document and editor binding", await evaluate('document.querySelector("#body-doc").doc === savedDoc && document.querySelector("#body-doc").provider === savedProvider && document.querySelector("#body-doc").mountCount === 1'));
  await evaluate('window.moved = document.querySelector("#body-doc"); moved.remove()');
  await wait('moved.provider === undefined && savedDoc.isDestroyed');
  await evaluate('document.querySelector("#move-target").append(moved)');
  await wait('moved.provider.synced');
  check("clean delayed reinsertion reconstructs saved content", await evaluate('moved.provider !== savedProvider && moved.doc.getText("content").toString() === "before move"'));
  await evaluate('window.savedDoc = moved.doc; window.savedProvider = moved.provider; window.sessionStore = DocumentSessionStore.for(savedProvider.consumer); void 0');
  await browser(session, "find", "label", "Encrypted text", "fill", "encrypted browser edit");
  await wait('!document.querySelector("#secret-doc").provider.hasPending');
  const encrypted = await state("secret");
  check("encrypted browser edit reads through declared storage", encrypted.text === "encrypted browser edit" && encrypted.storage === "Y::EncryptedDocument");
  check("encrypted payload has a ciphertext envelope", JSON.parse(Buffer.from(encrypted.raw_payload, "base64").toString()).p !== undefined);

  await browser(session, "find", "label", "Custom storage", "fill", "custom adapter browser edit");
  await wait('!document.querySelector("#external-doc").provider.hasPending');
  const custom = await state("external");
  check("custom storage serves both browser writes and native Ruby reads without built-in rows",
    custom.text === "custom adapter browser edit" && custom.storage === "BrowserStore" && custom.built_in_rows === 0);

  // Suspend managed subscriptions while leaving HTTP available for Turbo Drive.
  await evaluate('sessionStore.suspend(); window.suspendedSockets = socketCount');
  await wait('!savedProvider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  check("edit is pending and absent from storage before navigating", await evaluate('savedProvider.hasPending') && (await state("body")).text === "before move");
  // Located by visible text: agent-browser 0.28's role lookup misses links
  // and headings (buttons resolve fine), so a role locator finds nothing here.
  await browser(session, "find", "text", "Away", "click");
  // wait --url hangs in agent-browser 0.28 even when the URL already matches,
  // so check location directly through the --fn wait that works.
  await wait("location.pathname === '/away'");
  check("Turbo navigation stays in the same JS context", await evaluate('!!window.savedDoc'));
  check("pending session survives page removal without a replacement subscription", await evaluate('!savedDoc.isDestroyed && savedProvider.hasPending && savedProvider.status === "disconnected"'));
  check("no CRDT snapshot bytes are written into cached elements", await evaluate('!moved.hasAttribute("data-yrby-snapshot")'));
  await browser(session, "back");
  await wait('document.querySelector("#body-doc")?.doc === savedDoc');
  check("suspended history restore reuses the pending session without reopening the socket", await evaluate('socketCount === suspendedSockets && document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"'));
  await evaluate('sessionStore.resume()');
  await wait('document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("actual Turbo history restore retains and acknowledges the unsent edit", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"') && (await state("body")).text === "pending across Turbo");
  // Drop the actual socket without suspending the store, then restore transport.
  await evaluate(`window.networkSession = document.querySelector("#body-doc").session;
    window.networkConnection = networkSession.provider.consumer.connection;
    window.networkOpen = networkConnection.open; networkConnection.open = () => false;
    networkConnection.webSocket.close();`);
  await wait('!networkSession.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "network drop recovered");
  await browser(session, "find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
  check("transport loss preserves detached delivery", await evaluate('networkSession.state === "draining" && networkSession.hasPending'));
  await browser(session, "back");
  await wait('document.querySelector("#body-doc")?.session === networkSession');
  await evaluate('networkConnection.open = networkOpen; networkConnection.open()');
  await wait('networkSession.provider.synced && !networkSession.hasPending');
  check("real socket reconnection delivers the offline edit", (await state("body")).text === "network drop recovered");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!networkSession.hasPending');
  await browser(peer, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced', peer);
  check("a fresh browser reads the recovered edit from the server", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbo"', peer));
  await browser(session, "screenshot", `${root}tmp/element-browser.png`);

  // An advance visit first renders the cached preview, then replaces it with
  // fresh server HTML. Hold that response so the transient page is observable.
  await evaluate('window.beforePreview = document.querySelector("#body-doc"); window.outgoingPreviewDoc = beforePreview.doc; window.outgoingPreviewProvider = beforePreview.provider; window.previewConsumer = beforePreview.provider.consumer; sessionStore.suspend()');
  await wait('!beforePreview.provider.synced');
  await browser(session, "find", "label", "Body", "fill", "pending before preview");
  check("preview regression starts with an unacknowledged edit", await evaluate('beforePreview.provider.hasPending'));
  await browser(session, "find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
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
  await evaluate('releaseFresh(); window.fetch = originalFetch');
  await wait('!document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector("#body-doc") !== previewElement');
  check("fresh page stays inert and offline during explicit suspension", await evaluate('document.querySelector("#body-doc").inert && document.querySelector("#body-doc").provider.status === "disconnected"'));
  await evaluate('sessionStore.resume()');
  await wait('!document.documentElement.hasAttribute("data-turbo-preview") && document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("transient previews never allocate a document", await evaluate('previewDoc === undefined && previewElement.doc === undefined && previewElement.provider === undefined'));
  await wait('outgoingPreviewDoc.isDestroyed && !outgoingPreviewProvider.hasPending && document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"');
  check("fresh page has a newly minted grant", await evaluate('beforePreview.getAttribute("grant") !== document.querySelector("#body-doc").getAttribute("grant")'));
  check("fresh HTML receives and acknowledges the pre-preview pending edit", await evaluate('document.querySelector("#body-doc").doc.getText("content").toString() === "pending before preview"') && (await state("body")).text === "pending before preview");
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!document.querySelector("#body-doc").provider.hasPending');

  // Same grant: multiple editors share one queue and release independently.
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
  check("removing one view preserves the other binding", await evaluate('primary.provider.synced && primary.doc.getText("content").toString() === "shared views" && secondView.unmountCount === 1'));

  // A morph switches bindings while the old session drains under its own grant.
  await evaluate(`window.morphElement = primary;
    window.morphSession = primary.session; window.originalGrant = primary.getAttribute("grant");
    window.mountsBeforeMorph = primary.mountCount;
    sessionStore.suspend();`);
  await browser(session, "find", "label", "Body", "fill", "private body pending");
  await evaluate(`const replacement = morphElement.cloneNode(true);
    replacement.setAttribute("grant", document.querySelector("#secret-doc").getAttribute("grant"));
    replacement.setAttribute("name", "secret");
    Turbo.renderStreamMessage('<turbo-stream action="replace" method="morph" target="body-doc"><template>' + replacement.outerHTML + '</template></turbo-stream>');`);
  await wait('document.querySelector("#body-doc").getAttribute("name") === "secret" && morphElement.session !== morphSession');
  check("Turbo morph switches attachments and preserves the original pending queue", await evaluate('document.querySelector("#body-doc") === morphElement && morphSession.hasPending && morphSession.descriptor.grant === originalGrant && morphElement.session === document.querySelector("#secret-doc").session && morphElement.mountCount === mountsBeforeMorph + 1'));
  await evaluate('sessionStore.resume()');
  await wait('morphSession.state === "closed" && morphElement.provider.synced');
  check("original tail reaches only its original Ruby document", (await state("body")).text === "private body pending" && (await state("secret")).text === "encrypted browser edit");
  await evaluate('morphElement.setAttribute("grant", originalGrant); morphElement.setAttribute("name", "body")');
  await wait('morphElement.provider?.synced && morphElement.doc.getText("content").toString() === "private body pending"');
  await browser(session, "find", "label", "Body", "fill", "pending across Turbo");
  await wait('!morphElement.provider.hasPending');

  // A before-cache event can leave the current page in place (canceled visit).
  await evaluate('window.beforeCancelMounts = morphElement.mountCount; document.dispatchEvent(new Event("turbo:before-cache"))');
  await wait('morphElement.provider?.synced && morphElement.mountCount === beforeCancelMounts + 1');
  check("canceled navigation rebinds the live editor once", await evaluate('morphElement.doc.getText("content").toString() === "pending across Turbo" && !morphElement.inert'));

  // Permanent DOM nodes still get a fresh editor binding after navigation.
  await evaluate('morphElement.setAttribute("data-turbo-permanent", ""); window.permanentMounts = morphElement.mountCount; Turbo.visit("/?permanent=1")');
  await wait('location.search === "?permanent=1" && document.querySelector("#body-doc")?.provider?.synced');
  check("Turbo permanent element is rebound without duplicating editor listeners", await evaluate('document.querySelector("#body-doc") === morphElement && morphElement.mountCount > permanentMounts && morphElement.mountCount - morphElement.unmountCount === 1'));

  await browser(session, "open", `${base}/?detach=1`);
  await wait('document.querySelector("#secret-doc")?.provider?.synced');
  check("removal during the real dynamic import does not subscribe", await evaluate('!!window.detachedElement && detachedElement.provider === undefined'));
  await evaluate('document.body.append(detachedElement)');
  await wait('detachedElement.provider?.synced');
  check("reinsert after async cancellation subscribes successfully", await evaluate('detachedElement.doc.getText("content").toString() === "pending across Turbo"'));
  // Use a real Rails subscription, retain its obsolete callbacks, and replace it.
  await evaluate(`window.guardSession = detachedElement.session;
    window.guardProvider = guardSession.provider;
    window.guardStore = DocumentSessionStore.for(guardProvider.consumer);
    window.oldGuardSubscription = guardProvider.consumer.subscriptions.subscriptions.find(sub =>
      sub.identifier === JSON.stringify({ channel: guardProvider.channelName, ...guardProvider.channelParams }));
    guardStore.suspend();`);
  await wait('guardProvider.status === "disconnected"');
  await evaluate('guardStore.resume()');
  await wait('guardProvider.synced');
  check("late callbacks from a real retired subscription cannot pause or reject the replacement",
    await evaluate(`oldGuardSubscription.disconnected(); oldGuardSubscription.rejected();
      guardSession.state === "attached" && guardSession.provider === guardProvider && guardProvider.synced`));
  await browser(session, "find", "label", "Body", "fill", "guarded reconnect edit");
  await wait('!guardSession.hasPending');
  check("typing after stale callbacks still persists through the live replacement", (await state("body")).text === "guarded reconnect edit");
  // The managed subscription nonce works with the actual AnyCable web client.
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
  check("AnyCable replacement uses a fresh ack route and reconstructs saved content", await evaluate('anyElement.provider.channelParams.session_id !== oldAnyRoute && anyElement.doc.getText("content").toString() === "AnyCable session edit"'));
  await evaluate('anyElement.remove(); anyConsumer.disconnect(); YrbyDocumentElement.consumer = undefined');

  // A grant that expired while the socket was open is refreshed on reconnect.
  // The notes document's grant lives two seconds. Let it expire, drop the
  // socket so Action Cable resubscribes with the stale grant, and the element
  // must fetch a fresh one from /grant and carry on with the same session.
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
  check("an expired grant is refreshed on reconnect and the same session keeps delivering",
    (await state("notes")).text === "after grant refresh" && await evaluate('notesSession.doc === notesDoc && refreshCalls === 1'));

  // A copied, valid grant cannot bypass the authenticated connection's policy.
  await browser(peer, "open", `${base}/?user=visitor`);
  await wait('documentErrors.some(event => event.id === "body-doc" && event.session?.state === "blocked")', peer);
  check("a valid grant is rejected for a user without edit permission", await evaluate(
    'document.querySelector("#body-doc").mountCount === undefined && document.querySelector("#body-doc").querySelector("textarea").disabled', peer));
  await wait('document.querySelector("#secret-doc")?.provider?.synced', peer);

  // The policy runs when a client subscribes, so revoking permission does not
  // reach a subscription that is already open. It takes effect on the next one.
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
  check("revocation leaves other subscriptions on the socket working", (await state("secret")).text === "other subscription still works" &&
    await evaluate('socketCount === beforeDenialSockets'));

  // Reloading resubscribes, and that is where the revocation lands.
  await browser(session, "open", base);
  await wait('documentErrors.some(event => event.id === "body-doc" && event.session?.state === "blocked")');
  check("the next subscription is refused once permission is gone", await evaluate(
    'document.querySelector("#body-doc").querySelector("textarea").disabled'));

  // An authorized peer still works, and restoring permission lets this user back.
  const restore = await fetch(`${base}/permission?editor=editor`, { method: "POST" });
  assert.equal(restore.status, 204);
  await browser(peer, "open", base);
  await wait('document.querySelector("#body-doc")?.provider?.synced', peer);
  await browser(peer, "find", "label", "Body", "fill", "peer edit after revocation");
  await wait('!document.querySelector("#body-doc").provider.hasPending', peer);
  check("an authorized peer keeps editing throughout", (await state("body")).text === "peer edit after revocation");
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
