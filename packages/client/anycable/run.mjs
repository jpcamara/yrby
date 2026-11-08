// yrby behind anycable-go, with a Rage app (test/anycable) answering
// AnyCable's HTTP RPC. ActionCableProviders on their own WebSockets edit one
// document and must converge.
// Needs anycable-go on PATH, or its path in ANYCABLE_GO.
// From the repository root: bundle install && bundle exec rake compile
// From test/anycable: bundle install
// From packages/client: npm ci && npm run test:anycable
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, open, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import * as Y from "yjs";
import { ActionCableProvider } from "../dist/index.js";

// @rails/actioncable's ConnectionMonitor reads document visibility.
globalThis.document ??= { visibilityState: "visible", addEventListener() {}, removeEventListener() {} };
globalThis.window ??= globalThis;
globalThis.window.addEventListener ??= () => {};
globalThis.window.removeEventListener ??= () => {};
const { createConsumer } = await import("@rails/actioncable");

const root = fileURLToPath(new URL("../../../", import.meta.url));
const port = Number(process.env.PORT || 3811);
const [rpcPort, cablePort, broadcastPort] = [port, port + 1, port + 2];
const workers = process.env.WORKERS || "2";
const secret = "test-secret";
const base = `http://127.0.0.1:${rpcPort}`;
const cable = `ws://127.0.0.1:${cablePort}/cable`;
const room = `room-${Date.now()}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const check = (label, value) => { assert.ok(value, label); console.log(`PASS ${label}`); };
async function until(condition, label, ms = 10000) {
  const started = Date.now();
  while (!condition()) {
    if (Date.now() - started > ms) throw new Error(`timed out: ${label}`);
    await sleep(20);
  }
}

await mkdir(`${root}tmp`, { recursive: true });
const database = `${root}tmp/anycable-${port}.sqlite3`;
await rm(database, { force: true });
const rageLog = await open(`${root}tmp/anycable-rpc.log`, "w");
const rage = spawn("bundle", ["exec", "rage", "s", "-p", String(rpcPort), "-b", "127.0.0.1"], {
  cwd: `${root}test/anycable`,
  env: { ...process.env, BUNDLE_GEMFILE: `${root}test/anycable/Gemfile`, RAGE_ENV: "test", WORKERS: workers,
    DATABASE_URL: `sqlite3:${database}?timeout=5000`, ANYCABLE_SECRET: secret,
    ANYCABLE_BROADCAST_ADAPTER: "http",
    ANYCABLE_HTTP_BROADCAST_URL: `http://127.0.0.1:${broadcastPort}/_broadcast` },
  stdio: ["ignore", rageLog.fd, rageLog.fd],
});
rage.on("error", error => console.error(error));
const goLog = await open(`${root}tmp/anycable-go.log`, "w");
const go = spawn(process.env.ANYCABLE_GO || "anycable-go", [
  "--host", "127.0.0.1", "--port", String(cablePort), "--rpc_host", `${base}/_anycable`, "--secret", secret,
  "--broadcast_adapter", "http", "--http_broadcast_port", String(broadcastPort),
], { env: { ...process.env, ANYCABLE_DISABLE_TELEMETRY: "true" }, stdio: ["ignore", goLog.fd, goLog.fd] });
go.on("error", error => console.error(error));

const clients = [];
function client(name) {
  const doc = new Y.Doc();
  const consumer = createConsumer(cable);
  const errors = [];
  const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: room }, {
    onError: (error, context) => errors.push(`${context}: ${error?.message ?? error}`),
  });
  provider.connect();
  const c = { name, doc, consumer, provider, errors, text: doc.getText("body") };
  clients.push(c);
  return c;
}

// Resolves "confirmed", "rejected", or "disconnected" for one subscription.
async function subscribe(url, id) {
  const consumer = createConsumer(url);
  try {
    return await new Promise(resolve => {
      consumer.subscriptions.create({ channel: "DocumentChannel", id }, {
        connected: () => resolve("confirmed"),
        rejected: () => resolve("rejected"),
        disconnected: () => resolve("disconnected"),
      });
      setTimeout(() => resolve("timeout"), 5000);
    });
  } finally {
    consumer.disconnect();
  }
}

try {
  let up = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    if (rage.exitCode !== null) throw new Error(`Rage fixture exited ${rage.exitCode}; see tmp/anycable-rpc.log`);
    if (go.exitCode !== null) throw new Error(`anycable-go exited ${go.exitCode}; see tmp/anycable-go.log`);
    try {
      up = (await fetch(`${base}/docs/probe`)).status < 500 &&
        (await fetch(`http://127.0.0.1:${cablePort}/health`)).ok;
    } catch {}
    if (up) break;
    await sleep(100);
  }
  check(`anycable-go and the Rage RPC app boot (${workers} workers)`, up);

  const a = client("A");
  const b = client("B");
  await until(() => a.provider.synced && b.provider.synced, "both clients sync");
  check("both clients sync", true);

  for (let i = 0; i < 5; i++) {
    a.text.insert(0, `a${i} `);
    b.text.insert(b.text.length, `b${i} `);
  }
  await until(() => a.text.length === 30 && a.text.toString() === b.text.toString(), "convergence");
  check("concurrent edits converge", a.text.toString() === b.text.toString());
  await until(() => !a.provider.hasPending && !b.provider.hasPending, "acks");
  check("every update is acked", true);

  a.provider.awareness.setLocalStateField("user", { name: "alice" });
  await until(() => [...b.provider.awareness.getStates().values()].some(s => s.user?.name === "alice"), "awareness");
  check("awareness reaches the other client", true);

  const response = await fetch(`${base}/docs/${room}/append?text=FROM-RUBY`, { method: "POST" });
  assert.equal(response.status, 204);
  await until(() => [a, b].every(c => c.text.toString().endsWith("FROM-RUBY")), "Ruby-side write");
  check("a Ruby-side write reaches both clients through the HTTP broadcaster", true);

  const c = client("C");
  await until(() => c.provider.synced && c.text.toString() === a.text.toString(), "late joiner");
  check("a late joiner loads the document from storage", c.text.toString().endsWith("FROM-RUBY"));
  check("the store holds the merged document",
    (await (await fetch(`${base}/docs/${room}`)).text()) === a.text.toString());

  check("an unauthorized key is rejected", await subscribe(cable, "denied-1") === "rejected");
  check("a connection that identify refuses is closed", await subscribe(`${cable}?token=invalid`, room) === "disconnected");
  check("identifiers from connect reach authorized?",
    await subscribe(`${cable}?user=alice`, "private-1") === "confirmed" &&
    await subscribe(`${cable}?user=bob`, "private-1") === "rejected");
  const token = await (await fetch(`${base}/token?user=alice`)).text();
  check("identifiers from a JWT reach authorized?",
    await subscribe(`${cable}?jid=${encodeURIComponent(token)}`, "private-1") === "confirmed");

  for (const x of clients) assert.deepEqual(x.errors, [], `${x.name} reported no errors`);
  console.log("RESULT ok");
} finally {
  for (const x of clients) { x.provider.destroy(); x.consumer.disconnect(); }
  go.kill("SIGTERM");
  rage.kill("SIGTERM");
}
process.exit(0);
