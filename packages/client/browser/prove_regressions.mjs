// Real-Chrome reproducers for two lifecycle failures in PR #83.
//
// From the repository root:
//   bundle exec rake compile
// From packages/client:
//   npm run build
//   node browser/prove_regressions.mjs
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, open, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const assets = `${root}tmp/browser-assets`;
const port = process.env.PORT || "3791";
const base = `http://127.0.0.1:${port}`;
const ab = process.env.AB_BIN || "agent-browser";
const anySession = `yrby-proof-anycable-${process.pid}`;
const raceSession = `yrby-proof-renewal-${process.pid}`;
const ruby = process.env.RUBY_BIN;
const bundle = process.env.BUNDLE_BIN;
const serverCommand = ruby || "bundle";
const serverArgs = ruby
  ? [bundle, "exec", "ruby", "-Ilib", "test/browser/app.rb"]
  : ["exec", "ruby", "-Ilib", "test/browser/app.rb"];

await mkdir(assets, { recursive: true });
await build({
  entryPoints: [fileURLToPath(new URL("client.js", import.meta.url))],
  bundle: true,
  splitting: true,
  format: "esm",
  outdir: assets,
});
const logPath = `${root}tmp/browser-proof-server.log`;
const log = await open(logPath, "w");
const server = spawn(serverCommand, serverArgs, {
  cwd: root,
  env: {
    ...process.env,
    PORT: port,
    BROWSER_ASSETS: assets,
    DATABASE_URL: `sqlite3:${root}tmp/browser-proof-${port}.sqlite3`,
    SIMULATE_ANYCABLE_COMMANDS: "1",
  },
  stdio: ["ignore", log.fd, log.fd],
});
server.on("error", error => console.error(error));

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function browser(who, ...args) {
  const { stdout } = await exec(ab, ["--session", who, "--json", ...args], {
    timeout: 30000,
    maxBuffer: 2 ** 20,
  });
  const response = JSON.parse(stdout);
  if (!response.success) throw new Error(JSON.stringify(response.error));
  return response.data;
}
const evaluate = async (who, code) =>
  (await browser(who, "eval", "-b", Buffer.from(code).toString("base64"))).result;
const wait = (who, condition) => browser(who, "wait", "--fn", condition);
const check = (label, value) => {
  assert.ok(value, label);
  console.log(`PASS reproduced: ${label}`);
};
async function state(name) {
  const response = await fetch(`${base}/state/${name}`);
  assert.equal(response.status, 200);
  return response.json();
}
async function showProof(who, lines, screenshot) {
  await evaluate(who, `document.body.innerHTML = \`
    <main style="font: 20px/1.5 system-ui; max-width: 900px; margin: 60px auto">
      <h1>PR #83 browser regression reproduced</h1>
      ${lines.map(line => `<p>✅ ${line}</p>`).join("")}
      <p><strong>Browser:</strong> <span id="ua"></span></p>
    </main>\`;
    document.querySelector("#ua").textContent = navigator.userAgent;`);
  await browser(who, "screenshot", screenshot);
}

try {
  let up = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) {
      throw new Error(`Rails fixture exited ${server.exitCode}; see ${logPath}`);
    }
    try {
      up = (await fetch(base)).ok;
    } catch {}
    if (up) break;
    await sleep(100);
  }
  assert.ok(up, "Rails fixture boots");

  // Reproduce AnyCable's split between persisted authorized_document_key and
  // the ordinary @record instance variable. The fixture drops @record before
  // each receive, exactly as a fresh command instance does.
  await browser(anySession, "open", base);
  await wait(anySession, 'document.querySelector("#notes-doc")?.provider?.synced');
  await browser(anySession, "find", "label", "Notes", "fill", "saved before expiry");
  await wait(anySession, '!document.querySelector("#notes-doc").provider.hasPending');
  assert.equal((await state("notes")).text, "saved before expiry");
  await browser(anySession, "wait", "3000");
  await browser(anySession, "find", "label", "Notes", "fill", "write after expiry");
  await wait(anySession, 'document.querySelector("#notes-doc").provider.hasPending');
  await browser(anySession, "wait", "1000");
  const expiredResult = await evaluate(anySession, `({
    pending: document.querySelector("#notes-doc").provider.hasPending,
    text: document.querySelector("#notes-doc").doc.getText("content").toString()
  })`);
  check(
    "fresh-command receive leaves the expired-grant edit unacknowledged",
    expiredResult.pending && expiredResult.text === "write after expiry",
  );
  check(
    "fresh-command receive does not persist the edit",
    (await state("notes")).text === "saved before expiry",
  );
  await log.sync();
  check(
    "the server raises while calling append through a nil document",
    (await readFile(logPath, "utf8")).includes("undefined method 'append' for nil"),
  );
  await showProof(anySession, [
    "Expired open grant: browser edit stayed pending",
    "Server storage remained unchanged",
    "Server raised document.append on nil",
  ], `${process.env.ARTIFACT_DIR || `${root}tmp`}/anycable_expired_grant_proof.png`);

  // Hold the first successful refresh response. Acquiring a second lease while
  // it is in flight reconnects with the stale grant, whose rejection blocks the
  // session. Releasing the successful response then proves it is discarded.
  await browser(raceSession, "open", base);
  await wait(raceSession, 'document.querySelector("#notes-doc")?.provider?.synced');
  await evaluate(raceSession, `window.raceElement = document.querySelector("#notes-doc");
    window.raceSession = raceElement.session;
    window.originalGrant = raceSession.provider.channelParams.grant;
    window.refreshCalls = 0;
    window.realFetch = window.fetch;
    window.fetch = (...args) => {
      const url = new URL(args[0].url || args[0], location.href);
      if (url.pathname !== "/grant") return realFetch(...args);
      refreshCalls++;
      if (refreshCalls !== 1) return realFetch(...args);
      return new Promise(resolve => {
        window.releaseFirstGrant = () => resolve(realFetch(...args));
      });
    };`);
  await browser(raceSession, "wait", "3000");
  await evaluate(raceSession, `raceSession.provider.consumer.connection.webSocket.close();
    raceSession.doc.getText("content").insert(0, "queued while renewing");`);
  await wait(raceSession, "refreshCalls === 1 && !!releaseFirstGrant");
  await evaluate(raceSession, `window.secondLeaseElement = raceElement.cloneNode(true);
    secondLeaseElement.id = "second-notes";
    document.body.append(secondLeaseElement);`);
  await wait(raceSession, 'raceSession.state === "blocked"');
  await evaluate(raceSession, "releaseFirstGrant()");
  await browser(raceSession, "wait", "1000");
  const blockedResult = await evaluate(raceSession, `({
    state: raceSession.state,
    pending: raceSession.hasPending,
    grantWasKept: raceSession.provider.channelParams.grant !== originalGrant,
    refreshCalls
  })`);
  check(
    "a stale second lease blocks the session while renewal is in flight",
    blockedResult.state === "blocked" && blockedResult.pending,
  );
  check(
    "the successful first refresh is discarded",
    !blockedResult.grantWasKept && blockedResult.refreshCalls === 1,
  );
  await evaluate(raceSession, `raceSession.retry();
    window.retryUsedStaleGrant = raceSession.provider.channelParams.grant === originalGrant;`);
  await wait(raceSession, "refreshCalls === 2");
  check(
    "retry reconnects with the stale grant and requires another refresh",
    await evaluate(raceSession, "retryUsedStaleGrant && refreshCalls === 2"),
  );
  await showProof(raceSession, [
    "Concurrent lease blocked the renewing session",
    "Successful refreshed grant was discarded",
    "Retry used the stale grant and triggered a second refresh",
  ], `${process.env.ARTIFACT_DIR || `${root}tmp`}/grant_refresh_race_proof.png`);

  console.log("PASS both regressions reproduced in real Chrome");
} finally {
  for (const who of [anySession, raceSession]) {
    await browser(who, "close").catch(() => {});
  }
  server.kill("SIGTERM");
  await log.close();
}
