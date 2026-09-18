// Real-Chrome regression for Turbolinks 5, the predecessor of Turbo: the same
// fixture app, bundled with Turbolinks instead of Turbo.
// From packages/client: npm run test:browser:turbolinks
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, open } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const assets = `${root}tmp/browser-assets-turbolinks`;
const port = process.env.PORT || "3791";
const base = `http://127.0.0.1:${port}`;
const ab = process.env.AB_BIN || "agent-browser";
const session = process.env.AB_SESSION || `yrby-turbolinks-${process.pid}`;
await mkdir(assets, { recursive: true });
await build({ entryPoints: [fileURLToPath(new URL("client_turbolinks.js", import.meta.url))], bundle: true,
  splitting: true, format: "esm", outdir: assets });
const log = await open(`${root}tmp/browser-server-turbolinks.log`, "w");
const server = spawn("bundle", ["exec", "ruby", "-Ilib", "test/browser/app.rb"], {
  cwd: root, env: { ...process.env, PORT: port, BROWSER_ASSETS: assets, BROWSER_FRAMEWORK: "turbolinks",
    DATABASE_URL: `sqlite3:${root}tmp/browser-turbolinks-${port}.sqlite3` }, stdio: ["ignore", log.fd, log.fd],
});
server.on("error", error => console.error(error));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function browser(...args) {
  const { stdout } = await exec(ab, ["--session", session, "--json", ...args], { timeout: 30000, maxBuffer: 2 ** 20 });
  const response = JSON.parse(stdout);
  if (!response.success) throw new Error(JSON.stringify(response.error));
  return response.data;
}
const evaluate = async code => (await browser("eval", "-b", Buffer.from(code).toString("base64"))).result;
const wait = condition => browser("wait", "--fn", condition);
const check = (label, value) => { assert.ok(value, label); console.log(`PASS ${label}`); };
async function state(name) {
  const response = await fetch(`${base}/state/${name}`);
  assert.equal(response.status, 200);
  return response.json();
}
try {
  let up = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(`Rails fixture exited ${server.exitCode}; see tmp/browser-server-turbolinks.log`);
    try { up = (await fetch(base)).ok; } catch {}
    if (up) break;
    await sleep(100);
  }
  assert.ok(up, "Rails fixture boots");
  await browser("open", base);
  await wait('!!window.Turbolinks && ["#body-doc", "#secret-doc", "#external-doc", "#notes-doc"].every(id => document.querySelector(id)?.provider?.synced)');
  check("Turbolinks page binds every element over one socket", await evaluate('window.socketCount === 1 && !window.Turbo'));
  await browser("find", "label", "Body", "fill", "before turbolinks");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("ordinary edit reaches Ruby", (await state("body")).text === "before turbolinks");

  // Take the cable down, edit, and navigate. before-cache must detach the editor
  // while the session keeps the edit; a history restore must reattach to it.
  await evaluate(`window.moved = document.querySelector("#body-doc");
    window.savedDoc = moved.doc; window.savedProvider = moved.provider; window.cable = savedProvider.consumer;
    window.cableOpen = cable.connection.open;
    window.goOffline = () => { cable.connection.open = () => false; cable.disconnect(); };
    window.goOnline = () => { cable.connection.open = cableOpen; cable.connect(); };
    goOffline(); window.socketsBefore = socketCount;`);
  await wait('!savedProvider.synced');
  await browser("find", "label", "Body", "fill", "pending across Turbolinks");
  check("edit is pending before navigating", await evaluate('savedProvider.hasPending') && (await state("body")).text === "before turbolinks");
  await browser("find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
  check("Turbolinks navigation stays in the same JS context", await evaluate('!!window.savedDoc && !!window.Turbolinks'));
  check("before-cache detached the editor and the session drains", await evaluate(
    'moved.unmountCount === 1 && !savedDoc.isDestroyed && savedProvider.hasPending && socketCount === socketsBefore'));
  await browser("back");
  await wait('document.querySelector("#body-doc")?.doc === savedDoc');
  check("history restore reattaches the pending session without a new socket", await evaluate(
    'socketCount === socketsBefore && document.querySelector("#body-doc").session.state === "open" && savedDoc.getText("content").toString() === "pending across Turbolinks"'));
  await evaluate("goOnline()");
  await wait('document.querySelector("#body-doc")?.provider?.synced && !document.querySelector("#body-doc").provider.hasPending');
  check("restore delivers the unsent edit", (await state("body")).text === "pending across Turbolinks");

  // An advance visit to a cached page shows a preview first. Turbolinks fetches
  // over XMLHttpRequest, so hold that request to keep the preview on screen.
  await browser("find", "text", "Away", "click");
  await wait("location.pathname === '/away'");
  await evaluate(`const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) { this.yrbyPath = new URL(url, location.href).pathname; return open.call(this, method, url, ...rest); };
    XMLHttpRequest.prototype.send = function(...args) {
      if (this.yrbyPath !== "/") return send.apply(this, args);
      window.releaseFresh = () => { XMLHttpRequest.prototype.open = open; XMLHttpRequest.prototype.send = send; send.apply(this, args); };
    };
    Turbolinks.visit("/");`);
  await wait('document.documentElement.hasAttribute("data-turbolinks-preview") && !!document.querySelector("#body-doc") && !!window.releaseFresh');
  check("Turbolinks preview is inert and never starts a provider", await evaluate(`window.previewElement = document.querySelector("#body-doc");
    previewElement.inert && !previewElement.provider && !previewElement.doc`));
  await evaluate("releaseFresh()");
  await wait('!document.documentElement.hasAttribute("data-turbolinks-preview") && document.querySelector("#body-doc") !== previewElement && document.querySelector("#body-doc")?.provider?.synced');
  check("fresh page binds once with the saved content", await evaluate(
    'document.querySelector("#body-doc").mountCount === 1 && !previewElement.provider && document.querySelector("#body-doc").doc.getText("content").toString() === "pending across Turbolinks"'));

  // A permanent element is carried into the next page and rebound once.
  await evaluate('window.permanent = document.querySelector("#body-doc"); permanent.setAttribute("data-turbolinks-permanent", ""); window.permanentMounts = permanent.mountCount; Turbolinks.visit("/?permanent=1")');
  await wait('location.search === "?permanent=1" && document.querySelector("#body-doc")?.provider?.synced');
  check("Turbolinks permanent element is rebound without duplicating editor listeners", await evaluate(
    'document.querySelector("#body-doc") === permanent && permanent.mountCount > permanentMounts && permanent.mountCount - permanent.unmountCount === 1'));
  await browser("find", "label", "Body", "fill", "typed after turbolinks visits");
  await wait('!document.querySelector("#body-doc").provider.hasPending');
  check("editing after the visits reaches Ruby", (await state("body")).text === "typed after turbolinks visits");

  const errors = await browser("errors");
  check("no browser exceptions", (errors.errors ?? []).length === 0);
  console.log("PASS element browser regression under Turbolinks 5");
} finally {
  await browser("close").catch(() => {});
  server.kill("SIGTERM");
  await log.close();
}
