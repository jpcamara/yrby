// End-to-end: yrby-client, unchanged, against a Rust AnyCable backend.
//
//   browser-ish clients (DocumentSessionStore + @anycable/web, over real WebSockets)
//     -> anycable-go (WebSockets, streams, whispers)
//     -> gRPC -> crates/yrby-anycable's demo example (the document channel in Rust)
//     -> HTTP broadcast -> anycable-go -> clients
//
// Boots both servers, runs the scenarios, and tears everything down. Needs
// anycable-go on PATH and cargo. Run from packages/client after `npm run build`:
//
//   node e2e/anycable_rust.mjs
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import * as Y from "yjs";
import {
  broadcastKey, check, client as cableClient, healthy, run, sleep, start, startAnycable, stop, type, verbose, waitFor,
} from "./harness.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const crates = path.resolve(here, "../../../crates");
const RPC_PORT = Number(process.env.RPC_PORT || 50151);
const HTTP_PORT = Number(process.env.HTTP_PORT || 3151);
const WS_PORT = Number(process.env.WS_PORT || 8151);
const SECRET = "yrby-e2e-secret";
const API = `http://127.0.0.1:${HTTP_PORT}`;
const CABLE = `ws://127.0.0.1:${WS_PORT}/cable`;
const client = () => cableClient(CABLE);
const anycable = () => startAnycable({ wsPort: WS_PORT, rpcHost: `127.0.0.1:${RPC_PORT}`, secret: SECRET });

async function boot() {
  execFileSync("cargo", ["build", "-q", "-p", "yrby-anycable", "--example", "demo"], { cwd: crates, stdio: "inherit" });
  const target = process.env.CARGO_TARGET_DIR || path.join(crates, "target");
  start("rust", path.join(target, "debug/examples/demo"), [], { env: {
    YRBY_RPC_ADDR: `127.0.0.1:${RPC_PORT}`,
    YRBY_HTTP_ADDR: `127.0.0.1:${HTTP_PORT}`,
    ANYCABLE_BROADCAST_URL: `http://127.0.0.1:${WS_PORT}/_broadcast`,
    ANYCABLE_BROADCAST_KEY: broadcastKey(SECRET),
    RUST_LOG: verbose ? "debug" : "warn",
  } });
  await healthy(`${API}/health`);
  await anycable();
}

// --- backend inspection --------------------------------------------------------
const grantFor = async (doc, ttl = 3600) =>
  (await (await fetch(`${API}/grant?doc=${doc}&name=body&ttl=${ttl}`)).json()).grant;
const serverDoc = async (doc) => (await (await fetch(`${API}/documents/${doc}`)).json());
async function serverText(doc) {
  const { state } = await serverDoc(doc);
  if (!state) return "";
  const ydoc = new Y.Doc();
  Y.applyUpdate(ydoc, Buffer.from(state, "base64"));
  return ydoc.getText("content").toString();
}
const setFaults = (doc, faults) =>
  fetch(`${API}/documents/${doc}/faults?${new URLSearchParams(faults)}`, { method: "POST" });
const awarenessViaRpc = async () => (await (await fetch(`${API}/stats`)).json()).awareness_via_rpc;

// --- scenarios -----------------------------------------------------------------
async function convergence() {
  console.log("\n--- Two clients converge through the Rust backend ---");
  const grant = await grantFor("doc-converge");
  const a = client().open({ grant });
  const b = client().open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);
  check("both sessions synced", true);

  type(a, "hello from A. ");
  await waitFor("B sees A's edit", () => b.text().includes("hello from A"));
  await waitFor("A's edit is acknowledged", () => !a.session.hasPending);
  type(b, "hi from B.");
  await waitFor("A sees B's edit", () => a.text().includes("hi from B"));
  await waitFor("B's edit is acknowledged", () => !b.session.hasPending);
  check("both documents match", a.text() === b.text());
  check("the Rust store holds both edits", (await serverText("doc-converge")) === a.text());

  const c = client().open({ grant });
  await c.session.whenSynced;
  check("a late joiner is served the stored document", c.text() === a.text());
  return { a, b };
}

async function presence({ a, b }) {
  console.log("\n--- Presence goes client to client as whispers ---");
  const before = await awarenessViaRpc();
  a.lease.setPresence({ user: { name: "Ada" } });
  const bAwareness = b.session.provider.awareness;
  await waitFor("B sees A's presence", () =>
    [...bAwareness.getStates().values()].some((state) => state?.user?.name === "Ada"));
  check("no awareness frame went through the backend", (await awarenessViaRpc()) === before);
  a.lease.setPresence(null);
  await waitFor("A's presence removal reaches B", () =>
    ![...bAwareness.getStates().values()].some((state) => state?.user?.name === "Ada"));
}

async function recordBeforeRelay() {
  console.log("\n--- Slow store: nothing is relayed or acked until it is stored ---");
  const doc = "doc-slow";
  const grant = await grantFor(doc);
  const a = client().open({ grant });
  const b = client().open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);
  await setFaults(doc, { delay_ms: 1500 });

  type(a, "SLOW");
  await sleep(600);
  check("B does not see it mid-store", !b.text().includes("SLOW"));
  check("the store does not have it yet", !(await serverText(doc)).includes("SLOW"));
  check("A still has it pending", a.session.hasPending);
  await waitFor("B sees it once stored", () => b.text().includes("SLOW"), 5000);
  await waitFor("A's edit is acknowledged once stored", () => !a.session.hasPending, 5000);
  await setFaults(doc, {});
}

async function storeFailure() {
  console.log("\n--- Store failure: rejected, invisible, then retried ---");
  const doc = "doc-fail";
  const grant = await grantFor(doc);
  const a = client().open({ grant });
  const b = client().open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);
  await setFaults(doc, { fail_appends: 1 });

  type(a, "RETRIED");
  await sleep(300);
  check("B never sees the rejected attempt", !b.text().includes("RETRIED"));
  check("the store does not have it", !(await serverText(doc)).includes("RETRIED"));
  check("A keeps it pending", a.session.hasPending);
  // ReliableSync retransmits unacked edits every second.
  await waitFor("the client's retransmit is recorded and relayed", () => b.text().includes("RETRIED"), 5000);
  await waitFor("and then acknowledged", () => !a.session.hasPending, 5000);
  check("the store has it", (await serverText(doc)).includes("RETRIED"));
}

async function reconnect() {
  console.log("\n--- anycable-go restarts: offline edits survive and deliver ---");
  const doc = "doc-reconnect";
  const grant = await grantFor(doc);
  const a = client().open({ grant });
  const b = client().open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);
  type(a, "before. ");
  await waitFor("B has the first edit", () => b.text().includes("before"));

  await stop("anycable-go");
  await waitFor("A notices the connection dropped", () => a.session.provider.status === "connecting");
  type(a, "offline A. ");
  type(b, "offline B. ");
  check("offline edits are pending", a.session.hasPending && b.session.hasPending);

  await anycable();
  await waitFor("A resyncs", () => a.session.provider.status === "synced", 30_000);
  await waitFor("B resyncs", () => b.session.provider.status === "synced", 30_000);
  await waitFor("both offline edits reach both clients", () =>
    [a, b].every((v) => v.text().includes("offline A") && v.text().includes("offline B")), 10_000);
  await waitFor("nothing is left pending", () => !a.session.hasPending && !b.session.hasPending, 10_000);
  check("the store matches the clients", (await serverText(doc)) === a.text());
}

async function grants() {
  console.log("\n--- Grants: refresh an expired one, block a forged one ---");
  const doc = "doc-grants";
  const expired = await grantFor(doc, -10);
  const refresh = `${API}/grant?doc=${doc}&name=body`;
  const a = client().open({ grant: expired, refresh });
  await waitFor("an expired grant is refreshed and the session syncs",
    () => a.session.provider.status === "synced", 10_000);
  check("the session is open", a.session.state === "open");
  type(a, "after refresh");
  await waitFor("edits made after the refresh are acknowledged", () => !a.session.hasPending);
  check("and stored", (await serverText(doc)).includes("after refresh"));

  const forged = client().open({ grant: "forged--00" });
  await waitFor("a forged grant without a refresh URL blocks the session",
    () => forged.session.state === "blocked");
  check("and opened nothing on the server", (await serverDoc("forged")).updates === 0);
}

await run("yrby-client syncs through anycable-go with a Rust gRPC backend", async () => {
  await boot();
  const pair = await convergence();
  await presence(pair);
  await recordBeforeRelay();
  await storeFailure();
  await reconnect();
  await grants();
});
