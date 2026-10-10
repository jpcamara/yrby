// End-to-end: yrby-client, unchanged, against a Loco app with a database.
//
//   clients (DocumentSessionStore + @anycable/web)
//     -> anycable-go -> gRPC -> examples/loco-demo (loco-yrby's initializer)
//     -> SQLite or Postgres: y_documents + y_document_updates, encrypted at
//        rest and compacted as yrby-rails does
//
// The database is inspected directly (sqlite3, or psql in the Postgres
// container) and decrypted here with node:crypto, so what is checked is what
// is on disk. Needs anycable-go and cargo, plus sqlite3, or Docker with a
// Postgres container for E2E_DB=postgres. Run from packages/client after
// `npm run build`:
//
//   node e2e/loco.mjs                    # SQLite
//   E2E_DB=postgres node e2e/loco.mjs    # Postgres
//
// For Postgres, PG_URL names the server (default: the yrby-pg container on
// 127.0.0.1:55432). The database is inspected with psql, inside that
// container (PG_CONTAINER, default yrby-pg) or, with PG_CONTAINER set empty,
// with a psql on PATH, as in CI.
import { execFileSync } from "node:child_process";
import { createDecipheriv, createHmac, pbkdf2Sync, randomBytes } from "node:crypto";
import { inflateSync } from "node:zlib";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import * as Y from "yjs";
import {
  check, client as cableClient, healthy, run, sleep, start, startAnycable, stop, type, verbose, waitFor,
} from "./harness.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, "../../../examples/loco-demo");
const HTTP_PORT = Number(process.env.HTTP_PORT || 5161);
const RPC_PORT = Number(process.env.RPC_PORT || 50161);
const WS_PORT = Number(process.env.WS_PORT || 8161);
const ANYCABLE_SECRET = "yrby-loco-e2e-anycable";
const GRANT_SECRET = "yrby-loco-e2e-grants";
// Active Record encryption settings, as a Rails app would have them.
const AR_PRIMARY_KEY = randomBytes(24).toString("hex");
const AR_SALT = randomBytes(24).toString("hex");
const COMPACT_EVERY = 16;
const API = `http://127.0.0.1:${HTTP_PORT}`;
const CABLE = `ws://127.0.0.1:${WS_PORT}/cable`;
const scratch = mkdtempSync(path.join(tmpdir(), "yrby-loco-"));

// --- the database ----------------------------------------------------------------
const BACKEND = process.env.E2E_DB === "postgres" ? "postgres" : "sqlite";
const PG = {
  container: process.env.PG_CONTAINER ?? "yrby-pg",
  user: "yrby",
  url: process.env.PG_URL || "postgres://yrby:yrby@127.0.0.1:55432",
  database: `yrby_e2e_${process.pid}`,
};
const SQLITE = path.join(scratch, "e2e.sqlite");
const DATABASE_URL = BACKEND === "postgres" ? `${PG.url}/${PG.database}` : `sqlite://${SQLITE}?mode=rwc`;
const psql = (database, query) =>
  PG.container
    ? execFileSync("docker", ["exec", PG.container, "psql", "-U", PG.user, "-d", database, "-At", "-c", query], { encoding: "utf8" })
    : execFileSync("psql", [`${PG.url}/${database}`, "-At", "-c", query], { encoding: "utf8" });
function createDatabase() {
  if (BACKEND === "postgres") psql("postgres", `CREATE DATABASE ${PG.database}`);
}
function dropDatabase() {
  if (BACKEND === "postgres") psql("postgres", `DROP DATABASE IF EXISTS ${PG.database} WITH (FORCE)`);
}
const sql = (query) => {
  if (BACKEND === "postgres") return JSON.parse(psql(PG.database, `SELECT coalesce(json_agg(t), '[]') FROM (${query}) t`));
  const out = execFileSync("sqlite3", ["-json", SQLITE, query], { encoding: "utf8" }).trim();
  return out ? JSON.parse(out) : [];
};
const hex = (column) => (BACKEND === "postgres" ? `encode(${column}, 'hex')` : `hex(${column})`);
const quote = (s) => `'${s.replaceAll("'", "''")}'`;

// Active Record encryption's format, decrypted here independently of Rust:
// JSON {"p": ciphertext, "h": {"iv", "at", "c"?}}, AES-256-GCM with no AAD,
// key PBKDF2-SHA256(primary_key, key_derivation_salt, 2^16), zlib if "c".
const AR_KEY = pbkdf2Sync(AR_PRIMARY_KEY, AR_SALT, 2 ** 16, 32, "sha256");
function arMessage(value) {
  if (value[0] !== 0x7b) return null; // "{"
  try { const m = JSON.parse(value.toString("utf8")); return typeof m.p === "string" ? m : null; } catch { return null; }
}
function openValue(value) {
  const message = arMessage(value);
  if (!message) return value;
  const decipher = createDecipheriv("aes-256-gcm", AR_KEY, Buffer.from(message.h.iv, "base64"));
  decipher.setAuthTag(Buffer.from(message.h.at, "base64"));
  const body = Buffer.concat([decipher.update(Buffer.from(message.p, "base64")), decipher.final()]);
  return message.h.c ? inflateSync(body) : body;
}
function stored(key) {
  const [doc] = sql(`SELECT id, ${hex("state")} AS state, record_type, record_id, name
                     FROM y_documents WHERE key = ${quote(key)}`);
  if (!doc) return { exists: false, state: false, clean: 0, pending: 0, text: "", raw: [] };
  const tail = sql(`SELECT ${hex("payload")} AS payload, pending FROM y_document_updates
                    WHERE document_id = ${doc.id} ORDER BY id`);
  const raw = [doc.state, ...tail.map((row) => row.payload)].filter(Boolean).map((h) => Buffer.from(h, "hex"));
  const ydoc = new Y.Doc();
  for (const value of raw) Y.applyUpdate(ydoc, openValue(value));
  return {
    exists: true,
    binding: [doc.record_type, Number(doc.record_id), doc.name],
    state: !!doc.state,
    clean: tail.filter((row) => !row.pending).length,
    pending: tail.filter((row) => row.pending).length,
    text: ydoc.getText("content").toString(),
    raw,
  };
}
const encryptedAtRest = (row, plaintext) =>
  row.raw.length > 0 && row.raw.every((value) => arMessage(value)) && !row.raw.some((value) => value.includes(Buffer.from(plaintext)));
const plainAtRest = (row) => row.raw.length > 0 && row.raw.every((value) => !arMessage(value));

// --- processes -----------------------------------------------------------------
async function startLoco() {
  const target = process.env.CARGO_TARGET_DIR || path.join(app, "target");
  start("loco", path.join(target, "debug/yrby_loco-cli"), ["start"], {
    cwd: app,
    env: {
      LOCO_ENV: "development",
      PORT: String(HTTP_PORT),
      BINDING: "127.0.0.1",
      DATABASE_URL,
      YRBY_RPC_ADDR: `127.0.0.1:${RPC_PORT}`,
      ANYCABLE_BROADCAST_URL: `http://127.0.0.1:${WS_PORT}/_broadcast`,
      ANYCABLE_SECRET,
      YRBY_GRANT_SECRET: GRANT_SECRET,
      YRBY_COMPACT_EVERY: String(COMPACT_EVERY),
      AR_ENCRYPTION_PRIMARY_KEY: AR_PRIMARY_KEY,
      AR_ENCRYPTION_KEY_DERIVATION_SALT: AR_SALT,
      LOG_LEVEL: verbose ? "debug" : "warn",
    },
  });
  await healthy(`${API}/_ping`);
}
async function boot() {
  execFileSync("cargo", ["build", "-q"], { cwd: app, stdio: "inherit" });
  createDatabase();
  await startLoco();
  await startAnycable({ wsPort: WS_PORT, rpcHost: `127.0.0.1:${RPC_PORT}`, secret: ANYCABLE_SECRET });
}

// --- users, posts, grants, and connection tokens --------------------------------------
const users = {};
async function signUp(name) {
  const account = { name, email: `${name.toLowerCase()}@example.com`, password: "correct horse" };
  const json = { "content-type": "application/json" };
  await fetch(`${API}/api/auth/register`, { method: "POST", headers: json, body: JSON.stringify(account) });
  const res = await fetch(`${API}/api/auth/login`, { method: "POST", headers: json,
    body: JSON.stringify({ email: account.email, password: account.password }) });
  const { token, pid } = await res.json();
  if (!token) throw new Error(`login failed for ${name}`);
  return (users[name] = { name, token, pid });
}
async function logIn() {
  await signUp("Ada");
  await signUp("Bob");
  // A browser sends Ada's login cookie with the client's grant refresh; Node
  // has no cookie jar, so attach it for the app's origin here.
  const plainFetch = globalThis.fetch;
  globalThis.fetch = (url, init = {}) => {
    if (!String(url).startsWith(API)) return plainFetch(url, init);
    const headers = new Headers(init.headers);
    if (!headers.has("cookie")) headers.set("cookie", `auth_token=${users.Ada.token}`);
    return plainFetch(url, { ...init, headers });
  };
}
const api = (path, init = {}, as = users.Ada) =>
  fetch(`${API}${path}`, { ...init, headers: { "content-type": "application/json", authorization: `Bearer ${as.token}`, ...init.headers } });
async function createPost(title) {
  const res = await api("/api/posts", { method: "POST", body: JSON.stringify({ title }) });
  if (res.status !== 201) throw new Error(`create post: ${res.status}`);
  return res.json();
}
const grantFor = async (post, name = "body") => (await (await api(`/api/posts/${post.id}/grant?name=${name}`)).json()).grant;
const refreshFor = (post) => `${API}/api/posts/${post.id}/grant?name=body`;
const keyOf = (post) => `post/${post.id}/body`;
const cableToken = async (user) => (await (await api("/api/cable/token", {}, user)).json()).token;

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const hs256 = (claims, secret) => {
  const body = `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(claims)}`;
  return `${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`;
};
// A yrby grant, signed here independently of the Rust code: the format is the
// contract, and this checks it from the other side.
const signGrant = (sub, { name = "body", ttl = 60 } = {}) =>
  hs256({ aud: "yrby", sub, name, exp: Math.floor(Date.now() / 1000) + ttl }, GRANT_SECRET);
// An AnyCable identification token, as the app would mint it.
const signConnection = (user, ttl) =>
  hs256({ ext: JSON.stringify({ user: user.pid }), exp: Math.floor(Date.now() / 1000) + ttl }, ANYCABLE_SECRET);

// A browser tab of `user`: connects with an AnyCable identification token and
// fetches a fresh one when anycable-go reports it expired.
async function client(user = users.Ada, token) {
  const jid = token ?? (await cableToken(user));
  return cableClient(`${CABLE}?jid=${jid}`, {
    tokenRefresher: async (transport) => transport.setParam("jid", await cableToken(user)),
  });
}
// A tab with no token: anycable-go asks the app's connect RPC, which reads the
// login cookie. undici's WebSocket takes headers, as a browser sends cookies.
function cookieClient(user) {
  class WithCookie extends WebSocket {
    constructor(url, protocols) {
      super(url, { protocols, headers: { cookie: `auth_token=${user.token}` } });
    }
  }
  return cableClient(CABLE, { websocketImplementation: WithCookie });
}

// --- scenarios -----------------------------------------------------------------
async function identification() {
  console.log("\n--- Connections are identified, through AnyCable ---");
  const post = await createPost("Identified");
  const grant = await grantFor(post);

  const token = (await client()).open({ grant });
  await waitFor("Ada, identified by an AnyCable token (no connect RPC), opens her post", () =>
    token.session.provider.status === "synced");
  const cookie = cookieClient(users.Ada).open({ grant });
  await waitFor("Ada, identified by her login cookie through the connect RPC, opens it too", () =>
    cookie.session.provider.status === "synced");
  const expired = (await client(users.Ada, signConnection(users.Ada, -5))).open({ grant });
  await waitFor("an expired connection token is refreshed, and the connection proceeds", () =>
    expired.session.provider.status === "synced", 15_000);

  const bob = (await client(users.Bob)).open({ grant });
  await waitFor("Bob, identified, cannot open Ada's post even holding her grant", () => bob.session.state === "blocked");
  check("and cannot get a grant for it", (await api(`/api/posts/${post.id}/grant?name=body`, {}, users.Bob)).status === 403);

  const anonymous = cableClient(CABLE).open({ grant });
  await sleep(2000);
  // Refused at connect, it never reaches a subscription verdict: not synced,
  // and not blocked either (a subscribe-time rejection would block it).
  check("an unidentified connection is refused before it can subscribe",
    anonymous.session.provider.status === "connecting" && anonymous.session.state === "open");
}

async function persisted() {
  console.log(`\n--- Edits are stored in ${BACKEND}, encrypted per attribute ---`);
  const post = await createPost("Persisted");
  const key = keyOf(post);
  const grant = await grantFor(post);
  const a = (await client()).open({ grant });
  const b = (await client()).open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);

  type(a, "hello from A. ");
  await waitFor("B sees A's edit", () => b.text().includes("hello from A"));
  await waitFor("A's edit is acknowledged", () => !a.session.hasPending);
  type(b, "hi from B.");
  await waitFor("both edits are acknowledged", () => !a.session.hasPending && !b.session.hasPending);
  await waitFor("A has B's edit", () => a.text() === b.text());

  const row = stored(key);
  check("y_documents has the document under its key", row.exists);
  check("the stored document, decrypted, matches the clients", row.text === a.text());
  check("every stored value is encrypted, and no plaintext is on disk", encryptedAtRest(row, "hello from A"));
  check("below the threshold it is all tail", !row.state && row.clean >= 2);
  check(`the document is bound to its post (Post, ${post.id}, body)`,
    JSON.stringify(row.binding) === JSON.stringify(["Post", post.id, "body"]));

  // Per attribute: Post declares only its body encrypted, not its notes.
  const notes = (await client()).open({ grant: await grantFor(post, "notes"), name: "notes" });
  await notes.session.whenSynced;
  type(notes, "notes are not secret");
  await waitFor("the post's notes are saved", () => !notes.session.hasPending);
  const notesRow = stored(`post/${post.id}/notes`);
  check("the notes document is stored in plaintext: only the body is declared encrypted",
    notesRow.text === "notes are not secret" && plainAtRest(notesRow));
}

async function compaction() {
  console.log(`\n--- ${COMPACT_EVERY * 3} separate edits: the tail compacts into the snapshot ---`);
  const post = await createPost("Compacted");
  const key = keyOf(post);
  const grant = await grantFor(post);
  const a = (await client()).open({ grant });
  const b = (await client()).open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);

  // Waiting for each ack makes each edit its own append (unacked edits are
  // merged into one resend).
  const total = COMPACT_EVERY * 3;
  let acked = 0;
  for (let i = 0; i < total; i++) {
    const writer = i % 2 ? b : a;
    type(writer, `[${i}]`);
    const deadline = Date.now() + 5000;
    while (writer.session.hasPending && Date.now() < deadline) await sleep(5);
    if (!writer.session.hasPending) acked++;
  }
  check(`all ${total} edits were acknowledged`, acked === total);
  await waitFor("both clients converge", () => a.text() === b.text() && a.text().includes(`[${total - 1}]`));

  const row = stored(key);
  check("the snapshot (y_documents.state) was written", row.state);
  check(`the tail was folded: ${row.clean} clean rows left, under ${COMPACT_EVERY}`, row.clean < COMPACT_EVERY);
  check("nothing is quarantined", row.pending === 0);
  check("the snapshot is encrypted too", encryptedAtRest(row, `[${total - 1}]`));
  check("snapshot plus tail is exactly the document", row.text === a.text());
  const missing = [...Array(total).keys()].filter((i) => !row.text.includes(`[${i}]`));
  check("no edit was lost to compaction", missing.length === 0);

  const late = (await client()).open({ grant });
  await late.session.whenSynced;
  check("a late joiner is served the compacted document", late.text() === a.text());
}

async function restart() {
  console.log("\n--- The Loco app restarts: it shuts down cleanly, edits wait, the database keeps everything ---");
  const post = await createPost("Restarted");
  const key = keyOf(post);
  const grant = await grantFor(post);
  const a = (await client()).open({ grant });
  const b = (await client()).open({ grant });
  await Promise.all([a.session.whenSynced, b.session.whenSynced]);
  type(a, "before restart. ");
  await waitFor("the first edit is acknowledged", () => !a.session.hasPending);

  const stopped = await stop("loco");
  check(`SIGTERM stops the app and its RPC server cleanly (exit ${stopped.code} in ${stopped.ms}ms)`,
    stopped.code === 0 && stopped.ms < 5000);
  type(a, "during A. ");
  type(b, "during B. ");
  await sleep(1500); // retransmits hit a backend that is down
  check("edits made while the app is down stay pending", a.session.hasPending && b.session.hasPending);
  check("and are not in the database", !stored(key).text.includes("during"));

  await startLoco();
  await waitFor("the edits are acknowledged once the app is back", () =>
    !a.session.hasPending && !b.session.hasPending, 15_000);
  await waitFor("both clients converge", () =>
    [a, b].every((v) => v.text().includes("during A") && v.text().includes("during B")));
  check("the database has everything", stored(key).text === a.text());

  // A new client after the restart: served from the database alone.
  const fresh = (await client()).open({ grant: await grantFor(post) });
  await fresh.session.whenSynced;
  check("a new client after the restart gets the full document", fresh.text() === a.text());
}

async function grants() {
  console.log("\n--- Grants find their post, as a signed GlobalID does ---");
  const post = await createPost("Granted");
  const subject = `Post/${post.pid}`;

  const a = (await client()).open({ grant: signGrant(subject, { ttl: -30 }), refresh: refreshFor(post) });
  await waitFor("an expired grant is refreshed through the post's grant action", () => a.session.provider.status === "synced");
  type(a, "after refresh");
  await waitFor("and its edits are acknowledged", () => !a.session.hasPending);
  check("and stored under the post's key", stored(keyOf(post)).text === "after refresh");

  const b = (await client()).open({ grant: signGrant(subject) });
  await b.session.whenSynced;
  check("a grant signed outside Rust opens the same document", b.text() === "after refresh");

  const refused = async (label, grant, name = "body") => {
    const view = (await client()).open({ grant, name });
    await waitFor(label, () => view.session.state === "blocked");
  };
  const genuine = signGrant(subject);
  // Flip the signature's first character: every bit of it is significant
  // (the last one carries base64 padding bits).
  const cut = genuine.lastIndexOf(".") + 1;
  const tampered = genuine.slice(0, cut) + (genuine[cut] === "A" ? "B" : "A") + genuine.slice(cut + 1);
  await refused("a tampered grant is refused", tampered);
  await refused("a grant for an attribute Post does not declare is refused", signGrant(subject, { name: "title" }), "title");
  await refused("a grant naming the row id instead of the pid is refused", signGrant(`Post/${post.id}`));
  await refused("a grant for an unregistered model is refused", signGrant(`Comment/${post.pid}`));

  const doomed = await createPost("Doomed");
  const doomedGrant = await grantFor(doomed);
  check("deleting the post succeeds", (await api(`/api/posts/${doomed.id}`, { method: "DELETE" })).status === 204);
  await refused("a deleted post's grant is refused", doomedGrant);
  check("and opened no document", !stored(keyOf(doomed)).exists);
}

await run(`yrby-client syncs through anycable-go with a Loco app on ${BACKEND}`, async () => {
  try {
    await boot();
    await logIn();
    await identification();
    await persisted();
    await compaction();
    await restart();
    await grants();
  } finally {
    await stop("loco");
    if (!verbose) {
      rmSync(scratch, { recursive: true, force: true });
      dropDatabase();
    }
  }
});
