// Shared plumbing for the end-to-end scripts: checks, child processes, and
// clients. Each client is its own @anycable/web consumer, so its own WebSocket,
// the way two browser tabs would be.
import { spawn } from "node:child_process";
import { createHmac } from "node:crypto";
import { createConsumer } from "@anycable/web";
import { DocumentSessionStore } from "../dist/index.js";

export const verbose = !!process.env.VERBOSE;
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let failures = 0;
export const check = (label, ok) => {
  console.log(`${ok ? "ok" : "FAIL"}: ${label}`);
  if (!ok) failures++;
};
export async function waitFor(label, predicate, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await predicate()) return check(label, true);
    await sleep(50);
  }
  check(`${label} (timed out after ${timeout}ms)`, false);
}

// --- processes ---------------------------------------------------------------
const processes = new Map();
export function start(name, command, args, { env = {}, cwd } = {}) {
  const child = spawn(command, args, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  const log = [];
  const keep = (chunk) => {
    log.push(chunk.toString());
    if (verbose) process.stdout.write(`[${name}] ${chunk}`);
  };
  child.stdout.on("data", keep);
  child.stderr.on("data", keep);
  processes.set(name, { child, log });
  return child;
}
// SIGTERM, then wait. Resolves to how the process ended and how long it took.
export async function stop(name) {
  const entry = processes.get(name);
  if (!entry) return null;
  processes.delete(name);
  if (entry.child.exitCode !== null) return { code: entry.child.exitCode, signal: null, ms: 0 };
  const started = Date.now();
  const exited = new Promise((resolve) => entry.child.once("exit", (code, signal) => resolve({ code, signal })));
  entry.child.kill("SIGTERM");
  return { ...(await exited), ms: Date.now() - started };
}
export async function healthy(url, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { if ((await fetch(url)).ok) return; } catch {}
    await sleep(100);
  }
  throw new Error(`${url} never became healthy`);
}

export const broadcastKey = (secret) => createHmac("sha256", secret).update("broadcast-cable").digest("hex");

export async function startAnycable({ wsPort, rpcHost, secret }) {
  start("anycable-go", "anycable-go", [
    "--host=127.0.0.1", `--port=${wsPort}`,
    `--rpc_host=${rpcHost}`,
    // With --secret set, anycable-go takes broadcasts on its main port,
    // authenticated with the key derived from the secret.
    "--broadcast_adapter=http", `--secret=${secret}`,
    "--log_level=warn",
  ]);
  await healthy(`http://127.0.0.1:${wsPort}/health`);
}

// --- clients -----------------------------------------------------------------
const clients = [];
// `options` go to @anycable/web's createConsumer: tokenRefresher,
// websocketImplementation, and so on.
export function client(cableUrl, options = {}) {
  const consumer = createConsumer(cableUrl, { logLevel: verbose ? "debug" : "error", ...options });
  const store = DocumentSessionStore.for(consumer);
  const self = {
    consumer,
    open(descriptor) {
      const lease = store.acquire({ name: "body", ...descriptor });
      return { lease, session: lease.session, text: () => lease.session.doc.getText("content").toString() };
    },
  };
  clients.push(self);
  return self;
}
export const type = (view, text) => {
  const content = view.session.doc.getText("content");
  content.insert(content.length, text);
};

// Run the scenarios, then tear everything down and exit with the verdict.
export async function run(summary, scenarios) {
  try {
    await scenarios();
  } catch (error) {
    failures++;
    console.error("\nerror:", error);
    for (const [name, { log }] of processes) console.error(`--- ${name} ---\n${log.join("").slice(-3000)}`);
  } finally {
    for (const c of clients) c.consumer.disconnect?.();
    for (const name of [...processes.keys()]) await stop(name);
  }
  console.log("");
  if (failures > 0) {
    console.log(`FAILED: ${failures}`);
    process.exit(1);
  }
  console.log(`PASS: ${summary}`);
  process.exit(0);
}
