// yrby on Rage: ActionCableProviders on their own WebSockets edit one
// document through a Rage::Cable channel (test/rage) and must converge.
// From the repository root: bundle install && bundle exec rake compile
// From test/rage: bundle install
// From packages/client: npm ci && npm run test:rage
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
const port = process.env.PORT || "3801";
const workers = process.env.WORKERS || "2";
const base = `http://127.0.0.1:${port}`;
const url = `ws://127.0.0.1:${port}/cable`;
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
const database = `${root}tmp/rage-${port}.sqlite3`;
await rm(database, { force: true });
const log = await open(`${root}tmp/rage-server.log`, "w");
const server = spawn("bundle", ["exec", "rage", "s", "-p", port, "-b", "127.0.0.1"], {
  cwd: `${root}test/rage`,
  env: { ...process.env, BUNDLE_GEMFILE: `${root}test/rage/Gemfile`, RAGE_ENV: "test", WORKERS: workers,
    DATABASE_URL: `sqlite3:${database}?timeout=5000` },
  stdio: ["ignore", log.fd, log.fd],
});
server.on("error", error => console.error(error));

const clients = [];
function client(name) {
  const doc = new Y.Doc();
  const consumer = createConsumer(url);
  const errors = [];
  const provider = new ActionCableProvider(doc, consumer, "DocumentChannel", { id: room }, {
    onError: (error, context) => errors.push(`${context}: ${error?.message ?? error}`),
  });
  provider.connect();
  const c = { name, doc, consumer, provider, errors, text: doc.getText("body") };
  clients.push(c);
  return c;
}

try {
  let up = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    if (server.exitCode !== null) throw new Error(`Rage fixture exited ${server.exitCode}; see tmp/rage-server.log`);
    try { up = (await fetch(`${base}/docs/probe`)).status < 500; } catch {}
    if (up) break;
    await sleep(100);
  }
  check(`Rage fixture boots (${workers} workers)`, up);

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
  check("a Ruby-side write reaches both clients", true);

  const c = client("C");
  await until(() => c.provider.synced && c.text.toString() === a.text.toString(), "late joiner");
  check("a late joiner loads the document from storage", c.text.toString().endsWith("FROM-RUBY"));
  check("the store holds the merged document",
    (await (await fetch(`${base}/docs/${room}`)).text()) === a.text.toString());

  const consumer = createConsumer(url);
  const rejected = await new Promise(resolve => {
    consumer.subscriptions.create({ channel: "DocumentChannel", id: "denied-1" },
      { rejected: () => resolve(true), connected: () => setTimeout(() => resolve(false), 1000) });
    setTimeout(() => resolve(false), 5000);
  });
  consumer.disconnect();
  check("an unauthorized key is rejected", rejected);

  for (const x of clients) assert.deepEqual(x.errors, [], `${x.name} reported no errors`);
  console.log("RESULT ok");
} finally {
  for (const x of clients) { x.provider.destroy(); x.consumer.disconnect(); }
  server.kill("SIGTERM");
}
process.exit(0);
