// yrby over the /yjs/ endpoint: raw binary y-protocols clients (no Action
// Cable framing) against the same Rage RPC app (test/anycable). /yjs/ is not
// in stock anycable-go. It comes from the Thruster fork with embedded
// AnyCable (github.com/jpcamara/thruster), so this script runs locally only:
//
//   THRUST=/path/to/thrust node anycable/yjs.mjs
//
// After the setup steps in run.mjs.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, open, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import * as Y from "yjs";
import * as sync from "y-protocols/sync";
import * as awarenessProtocol from "y-protocols/awareness";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";

if (!process.env.THRUST) throw new Error("set THRUST to a Thruster build with the /yjs/ endpoint");

const root = fileURLToPath(new URL("../../../", import.meta.url));
const port = Number(process.env.PORT || 3821);
const [httpPort, rpcPort, broadcastPort] = [port, port + 1, port + 2];
const secret = "test-secret";
const base = `http://127.0.0.1:${httpPort}`;
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
const database = `${root}tmp/anycable-yjs-${port}.sqlite3`;
await rm(database, { force: true });
const log = await open(`${root}tmp/anycable-yjs.log`, "w");
// Thruster proxies HTTP to Rage and runs anycable-go in-process, which calls
// Rage's /_anycable for RPC.
const server = spawn(process.env.THRUST, ["bundle", "exec", "rage", "s", "-p", String(rpcPort), "-b", "127.0.0.1"], {
  cwd: `${root}test/anycable`,
  env: { ...process.env, BUNDLE_GEMFILE: `${root}test/anycable/Gemfile`, RAGE_ENV: "test",
    DATABASE_URL: `sqlite3:${database}?timeout=5000`, HTTP_PORT: String(httpPort), TARGET_PORT: String(rpcPort),
    ANYCABLE_SECRET: secret, ANYCABLE_DISABLE_TELEMETRY: "true", ANYCABLE_BROADCAST_ADAPTER: "http",
    ANYCABLE_HTTP_BROADCAST_URL: `http://127.0.0.1:${broadcastPort}/_broadcast`,
    ANYCABLE_OPT: `--rpc_host=http://127.0.0.1:${rpcPort}/_anycable --secret=${secret} ` +
      `--broadcast_adapter=http --http_broadcast_port=${broadcastPort}` },
  stdio: ["ignore", log.fd, log.fd],
});
server.on("error", error => console.error(error));

const frame = write => { const e = encoding.createEncoder(); write(e); return encoding.toUint8Array(e); };

function client(name) {
  const doc = new Y.Doc();
  const awareness = new awarenessProtocol.Awareness(doc);
  const ws = new WebSocket(`ws://127.0.0.1:${httpPort}/yjs/`);
  ws.binaryType = "arraybuffer";
  const c = { name, doc, awareness, ws, text: doc.getText("body"), synced: false, pending: new Map(), nextId: 1 };
  ws.onopen = () => {
    const identifier = JSON.stringify({ channel: "DocumentChannel", id: room });
    ws.send(frame(e => { encoding.writeVarUint(e, 2); encoding.writeVarUint(e, 1); encoding.writeVarString(e, identifier); }));
    ws.send(frame(e => { encoding.writeVarUint(e, 0); sync.writeSyncStep1(e, doc); }));
  };
  ws.onmessage = ({ data }) => {
    if (typeof data === "string") return;
    const d = decoding.createDecoder(new Uint8Array(data));
    const kind = decoding.readVarUint(d);
    if (kind === 0) {
      const reply = encoding.createEncoder();
      encoding.writeVarUint(reply, 0);
      if (sync.readSyncMessage(d, reply, doc, "remote") === 1) c.synced = true; // the server's SyncStep2
      if (encoding.length(reply) > 1) ws.send(encoding.toUint8Array(reply));
    } else if (kind === 1) {
      awarenessProtocol.applyAwarenessUpdate(awareness, decoding.readVarUint8Array(d), "remote");
    } else if (kind === 101) {
      c.pending.delete(decoding.readVarUint(d));
    }
  };
  doc.on("update", (update, origin) => {
    if (origin === "remote") return;
    const id = c.nextId++;
    const f = frame(e => { encoding.writeVarUint(e, 100); encoding.writeVarUint(e, id); encoding.writeVarUint(e, 0); sync.writeUpdate(e, update); });
    c.pending.set(id, f);
    ws.send(f);
  });
  awareness.on("update", ({ added, updated, removed }, origin) => {
    if (origin === "remote") return;
    const changed = added.concat(updated, removed);
    ws.send(frame(e => { encoding.writeVarUint(e, 1); encoding.writeVarUint8Array(e, awarenessProtocol.encodeAwarenessUpdate(awareness, changed)); }));
  });
  return c;
}

let a, b;
try {
  let up = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    if (server.exitCode !== null) throw new Error(`thrust exited ${server.exitCode}; see tmp/anycable-yjs.log`);
    try { up = (await fetch(`${base}/docs/probe`)).status < 500; } catch {}
    if (up) break;
    await sleep(100);
  }
  check("thrust (embedded anycable-go with /yjs/) and the Rage RPC app boot", up);

  a = client("A");
  b = client("B");
  await until(() => a.synced && b.synced, "both clients sync");
  check("both binary clients sync through /yjs/", true);

  for (let i = 0; i < 5; i++) {
    a.text.insert(0, `a${i} `);
    b.text.insert(b.text.length, `b${i} `);
  }
  await until(() => a.text.length === 30 && a.text.toString() === b.text.toString(), "convergence");
  check("concurrent edits converge", true);
  await until(() => a.pending.size === 0 && b.pending.size === 0, "acks");
  check("every update is acked with a binary [101][id] frame", true);

  a.awareness.setLocalStateField("user", { name: "alice" });
  await until(() => [...b.awareness.getStates().values()].some(s => s.user?.name === "alice"), "awareness");
  check("awareness reaches the other client", true);

  const response = await fetch(`${base}/docs/${room}/append?text=FROM-RUBY`, { method: "POST" });
  assert.equal(response.status, 204);
  await until(() => [a, b].every(c => c.text.toString().endsWith("FROM-RUBY")), "Ruby-side write");
  check("a Ruby-side write reaches both binary clients", true);
  check("the store holds the merged document",
    (await (await fetch(`${base}/docs/${room}`)).text()) === a.text.toString());
  console.log("RESULT ok");
} finally {
  a?.ws.close();
  b?.ws.close();
  server.kill("SIGTERM");
}
process.exit(0);
