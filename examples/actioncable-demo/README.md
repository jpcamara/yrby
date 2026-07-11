# yrby ActionCable Demo

A collaborative Tiptap editor backed by Rails and ActionCable, with no Node
server. The Y.js sync protocol and awareness (shared cursors and presence) run
natively in Ruby through [yrby](../..).

```
Browser (Tiptap + Yjs + yrby-client) ⇄ ActionCable ⇄ DocumentChannel (Y::ActionCable::Sync)
```

The server can read the document too. `GET /docs/:id/content` returns the
authoritative CRDT state (base64), rebuilt from the durable store with no
headless browser and no JS. Apply it to a fresh Y.Doc to see what the server
sees.

## Run it

```bash
bundle install
bin/rails db:prepare

# Build the local client package used by the demo
cd ../../packages/client && npm install && npm run build && cd ../../examples/actioncable-demo

# Build the frontend bundle (requires bun)
cd frontend && bun install && bun run build && cd ..

bin/rails s
```

Open http://localhost:3000 in two windows and type. Text and cursors sync
between them. Open http://localhost:3000/docs/demo/content to watch the
server's own view of the document.

### Opaque-state demos

yrby moves opaque CRDT updates without knowing what shared types are inside,
so the same `DocumentChannel` syncs *any* Yjs shape. The same document is
reachable through several front ends (linked from the nav on each page):

| Page | Opaque state | Binding |
|------|--------------|---------|
| `/docs/demo` | `Y.XmlFragment` | Tiptap (rich text) |
| `/docs/demo/lexxy` | `Y.XmlText` | Lexxy / Lexical |
| `/docs/demo/rhino` | `Y.XmlFragment` | Rhino (Tiptap 3, raw y-prosemirror plugins) |
| `/docs/demo/codemirror` | `Y.Text` | CodeMirror 6 (code + cursors) |
| `/docs/demo/whiteboard` | `Y.Map` of shapes | draggable sticky notes |
| `/docs/demo/kanban` | `Y.Array` of card `Y.Map`s | add / move / delete |
| `/docs/demo/forms` | `Y.Map` of fields | co-filled form |

Each is a self-contained entry under `frontend/src/`; the only thing that differs
is the Yjs binding. A two-window agent-browser check for the last four lives in
`frontend/opaque_demos_e2e.mjs` (run the server with `STORE_KIND=file` first).

> The default durable store is Postgres, reached over the `/tmp` unix socket — so
> "Run it" above expects a local Postgres. To avoid that (or a port clash with
> your own services), use Docker below.

## Run it with Docker

The whole demo — Rails/Puma **web**, **Postgres**, and **Redis** — runs in
containers, with the services on **non-standard host ports** so they never
collide with a Postgres/Redis you already run locally:

```bash
cd examples/actioncable-demo
docker compose up --build
```

| Service  | Host port | In-container |
|----------|-----------|-------------|
| web      | **3100**  | 3000        |
| postgres | **5442**  | 5432        |
| redis    | **6399**  | 6379        |

Then open two windows:

- http://localhost:3100/docs/demo — the Tiptap editor
- http://localhost:3100/docs/demo/lexxy — the Lexxy editor (lexxy-realtime)
- http://localhost:3100/docs/demo/rhino — the Rhino editor (rhino-editor),
  with an ActionText save rendered server-side from the CRDT by `Y::Tiptap`

The image carries Rust (to compile the native extension) and bun (to build the
front end); the build context is the **repo root** because the demo uses the gem
via `path:` and the Lexxy page pulls [`lexxy-realtime`](https://github.com/jpcamara/lexxy-realtime)
(cloned at build; override with `--build-arg LEXXY_REALTIME_REF=<tag>`).

### Just the services (for host-run dev or the e2e suites)

To run the app/tests on the host but borrow the containerized Postgres/Redis on
their non-standard ports — no local pg/redis needed, no collisions:

```bash
docker compose up -d postgres redis

# point the app (or any test harness) at them:
export PGHOST=localhost PGPORT=5442 PGUSER=postgres PGPASSWORD=postgres
export REDIS_URL=redis://localhost:6399/15
bin/rails db:prepare && bin/rails s          # or: CABLE_ADAPTER=redis WORKERS=2 frontend/boot_server.sh
```

All of pg/redis wiring is env-driven (`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`,
`REDIS_URL`), so the same overrides retarget the demo, the multi-process run, and
the AnyCable run at the containerized services.

### AnyCable

Run the same demo over [AnyCable](https://anycable.io) — the Go WebSocket gateway
with channel logic in a separate Ruby RPC process — by applying the AnyCable
overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.anycable.yml up --build
# open http://localhost:3100/docs/demo/lexxy in two windows
```

This adds two services to the base pg/redis/web stack:

| Service        | Role                                              | Host port |
|----------------|---------------------------------------------------|-----------|
| `anycable-rpc` | Ruby gRPC server — the `DocumentChannel` logic    | —         |
| `anycable-go`  | Go gateway — terminates browser WebSockets        | **8080**  |

`web` runs in `any_cable` mode (broadcasts via AnyCable instead of serving
WebSockets itself) and emits `CABLE_URL=ws://localhost:8080/cable` into the page
via `action_cable_meta_tag`, so the browser's `createConsumer()` connects to the
gateway automatically. The gateway calls the RPC server, which records to the
same Postgres store — so documents converge across the AnyCable path exactly as
on plain ActionCable.

## How it works

On the server, [`app/channels/document_channel.rb`](app/channels/document_channel.rb)
is the whole integration:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable::Sync

  on_load  { |key| Store.current.replay(key) }
  on_change { |key, update| Store.current.record(key, update) }

  def subscribed = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])
end
```

The channel is store-backed. `on_load` rebuilds state from the durable store;
`on_change` records each document delta before the server broadcasts or acks it.
No authoritative document state lives in ActionCable process memory.

The browser side uses `yrby-client`'s `ActionCableProvider`. Tiptap's
Collaboration and CollaborationCursor extensions plug into the provider's shared
`Y.Doc` and `Awareness` directly. Document frames use the canonical
`{ update, id }` envelope and are ack-tracked; awareness frames are ephemeral.

```js
import { createConsumer } from "@rails/actioncable"
import { ActionCableProvider } from "yrby-client"

const provider = new ActionCableProvider(ydoc, createConsumer(), "DocumentChannel", { id: documentId })
provider.connect()
```

## End-to-end test

With the server running:

```bash
cd frontend && bun e2e.mjs
```

Two simulated clients connect over raw WebSockets and check late-joiner
catch-up through the server, live updates in both directions, awareness
propagation, byte-for-byte CRDT convergence, the server-side state read
(`/content`), and presence reaping on disconnect (only the departed client's cursor
clears, well under the client-side timeout).

`bun reliable_provider.mjs` exercises the provider path on its own: document
sync in both directions, presence, byte-for-byte convergence, ack-tracked
delivery, and late-join.

### Real browser tests (agent-browser)

These drive real Chrome instances running the actual bundle (Tiptap plus the demo
provider) — the same stack a person uses — via
[agent-browser](https://www.npmjs.com/package/agent-browser), each browser an
isolated user in its own session. Unlike the headless raw-WebSocket suites they
exercise the real Tiptap ↔ provider editor binding, so they catch bundle-level
regressions (e.g. a duplicate `yjs` copy) the protocol-only tests can't.
agent-browser is a frontend devDependency, so no extra setup; both run in CI on
the Puma cluster.

```bash
bin/rails s -p 3777
cd frontend
PORT=3777 BROWSERS=4 PER=15 node agent_browsers.mjs   # concurrent typing
PORT=3777 node agent_collab.mjs                       # rich text + cursors
```

`agent_browsers.mjs` has four real browsers type their own digit into one doc at
the same time (including a same-position storm), then asserts every browser's
document is identical, every keystroke survived (counted per contributor), and
the durable store reflects them all.

`agent_collab.mjs` covers the harder multi-user cases: concurrent rich-text
merges (bold / italic / heading applied at once, converging with every mark and
block type preserved) and cursor/presence fidelity — named remote carets,
selection highlights, a caret surviving a concurrent edit by someone else, and
presence reaping when a user disconnects.

### Fiber scheduler (Falcon)

The whole e2e suite is server-agnostic — the harnesses just need the app on
`$PORT` — so the same scenarios run under either Puma (threaded) or
[Falcon](https://github.com/socketry/falcon) (fiber scheduler). Running them
under Falcon proves the native extension behaves correctly inside a fiber
reactor: it releases the GVL for CRDT work and must hold up with no deadlock and
no lost updates, with the durable store still replaying to the same document.

`boot_server.sh` boots either server (default `WORKERS=2`, a real multi-process
deployment where the durable store (not process memory) is authoritative);
`e2e_suite.sh` runs the shared durability/concurrency slice against it. Multiple
processes share documents only through the cable adapter, so a multi-process run
needs `CABLE_ADAPTER=redis` (the in-process `async` adapter can't span
processes; `boot_server.sh` fails fast without it):

```bash
# Falcon (fiber scheduler); use SERVER=puma for the threaded baseline.
export CABLE_ADAPTER=redis REDIS_URL=redis://localhost:6379/15
SERVER=falcon PORT=3778 SERVER_PIDFILE=/tmp/falcon.pid frontend/boot_server.sh
PORT=3778 frontend/e2e_suite.sh
kill "$(cat /tmp/falcon.pid)"
```

CI runs the slice under both a Puma cluster and a Falcon cluster (2 workers
each, Redis), plus the two-process cross-process test (`multiprocess.mjs`), the
agent-browser test on the Puma cluster, and the AnyCable stack (see below) — so
both ActionCable and AnyCable are covered.

## Durable store: Postgres or file

The demo always wires yrby's `on_load`/`on_change` to a durable store. Two
stores are included, selected by `STORE_KIND`:

- `pg` (default), in [`app/lib/pg_store.rb`](app/lib/pg_store.rb): a
  `document_changes` table with one committed row per change. It's a
  parameterized INSERT with a binary `bytea` bind and `synchronous_commit=on`,
  so the row is durable before `record` returns. This is the one closer to
  production: a single source of truth across every node, where the audit log is
  just the database.
- `file`, in [`app/lib/audit_log.rb`](app/lib/audit_log.rb): an fsync'd
  append-only log per document, with no database needed.

Set up the table once:

```bash
bin/rails db:prepare   # creates yrby_demo_development + document_changes
```

(`config/database.yml` defaults to the local socket as `$USER`.) `GET
/docs/:id/audit` returns the stored deltas (base64).

## Record Before Distribute

The channel records every change durably before it broadcasts or acknowledges
it, using yrby's `on_change` hook. `GET /docs/:id/audit` returns the log as
base64 CRDT deltas.

```bash
RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777

cd frontend && bun audit.mjs
```

A client makes a series of edits. The test then fetches the audit log, replays
it into a fresh `Y.Doc` without any help from the live server, and checks that
the result matches the server's live document byte-for-byte, which means the
recorded log is a complete history on its own. Recording before distributing
costs a synchronous durable write per change; that's the trade-off `on_change`
asks for.

`bun audit_scenarios.mjs` covers the harder cases. It drives a fault-injectable
store (slow or failing, via `POST /docs/:id/audit/control`) across several real
clients and checks the same guarantee throughout: no one else sees a change
until it's stored.

1. Slow store: while the store is in progress, no other client sees the change,
   not through a live broadcast, not through `GET /content`, and not through a
   fresh client's resync. Once the store finishes, everyone converges and it's
   logged.
2. Store failure: a failed store leaks nothing to anyone and never lands in the
   log. The originating client keeps its optimistic edit and diverges.
3. Self-heal: after a failure the client reconnects and re-offers the change,
   the recovered store records it, and everyone converges.
4. Offline catch-up: edits made offline are recorded as one merged diff when the
   client reconnects, before others see them.

## Hostile input (chaos)

```bash
bin/rails s -p 3777
cd frontend && bun chaos.mjs
```

A vandal client sprays malformed frames (bad base64, random bytes, truncated,
oversized, multi-message, and unknown-type protocol messages, spoofed
awareness, broken envelopes) while good clients edit. The test checks that the
server stays up, the good clients still converge byte-for-byte, a second room is
untouched, and garbage is never logged as a change. Malformed
or multi-message frames get dropped before they can be processed or relayed, so
one bad client can't disrupt the others.

## Crash recovery

```bash
bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=write bun crash_recovery.mjs
# ... kill -9 the server, then restart it ...
bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=verify bun crash_recovery.mjs
```

The file store fsyncs every change before it's broadcast, so every
acknowledged edit is on disk when the server dies. After a hard `kill -9` and
restart, `on_load` replays the log (`AuditLog.replay` tolerates a torn final
line from a crash mid-append) and the document comes back whole. A server that
persists on a debounce has a window where it can lose recent edits; this one
doesn't.

## Multi-process

Real Rails runs multiple processes. With a multi-process cable adapter
(`CABLE_ADAPTER=redis`) and a shared audit store, documents are shared across
processes. Boot two servers and split clients across them:

```bash
# needs a running Redis
redis-server &   # or `brew services start redis`

CABLE_ADAPTER=redis bin/rails s -p 3777 -P tmp/pids/s3777.pid &
CABLE_ADAPTER=redis bin/rails s -p 3778 -P tmp/pids/s3778.pid &

cd frontend && PORTS=3777,3778 bun multiprocess.mjs
```

Clients are split across the two processes. The test checks cross-process
convergence (byte-for-byte), server reads and late-join handshakes from the
shared store, cross-process presence, and a single shared audit log with every
change recorded exactly once.

Liveness rides the Redis cable adapter. The shared store is the source of truth
for every process via `on_load`, so record-before-distribute holds across
processes.

## AnyCable

AnyCable terminates WebSockets in a Go process and runs channel logic in a
separate Ruby RPC server. yrby's ActionCable concern is already stateless
and store-backed, so documents come from the durable store rather than process
memory.

```bash
# 1) AnyCable RPC server (channel logic in Ruby)
CABLE_ADAPTER=any_cable bundle exec anycable

# 2) anycable-go (WebSocket server, :8080; brew install anycable-go)
anycable-go --host=127.0.0.1 --port=8080 --rpc_host=127.0.0.1:50051 \
  --broadcast_adapter=redis --redis_url=redis://localhost:6379/15

# 3) Rails HTTP (pages + /content), broadcasting via AnyCable
CABLE_ADAPTER=any_cable bin/rails s -p 3777

# Probe + concurrent storm (WS on anycable-go :8080, HTTP on Puma :3777):
cd frontend
WS_PORT=8080 HTTP_PORT=3777 bun anycable_probe.mjs
WS_PORT=8080 HTTP_PORT=3777 CLIENTS=6 bun anycable_concurrent.mjs
PORT=8080 bun reliable_provider.mjs
```

`frontend/anycable_boot.sh` automates booting all three processes (RPC server,
anycable-go, Puma) and waits until the stack is healthy; CI uses it to run
`anycable_concurrent.mjs`, `anycable_guarantee.mjs`, and `reliable_provider.mjs`
through the gateway:

```bash
export REDIS_URL=redis://localhost:6379/15
HTTP_PORT=3797 WS_PORT=8080 ANYCABLE_PIDFILE=/tmp/anycable.pid frontend/anycable_boot.sh
cd frontend && WS_PORT=8080 HTTP_PORT=3797 CLIENTS=6 bun anycable_concurrent.mjs
kill $(cat /tmp/anycable.pid)
```

`anycable_probe.mjs` confirms liveness and that Puma's `/content` reflects the
document even though a different process (the RPC server) handled the edits.
`anycable_concurrent.mjs` runs a concurrent storm and checks convergence and
that the shared store reflects every edit. (`config/anycable.yml` holds the
broadcast adapter and RPC host.)

`anycable_guarantee.mjs` checks record-before-distribute under AnyCable: a
change stays invisible to other clients, to `/content`, to the audit store, and
to a fresh client's handshake until it has been stored, under both a slow store
and a failing store. It uses the audit fault controls, which are file-based so
they work across the Puma and RPC processes.

Real browsers through AnyCable: set `CABLE_URL` so the page points the browser
at anycable-go (`action_cable_meta_tag` emits it), then run the agent-browser
suites against the Puma page port. The WebSockets go to anycable-go:

```bash
CABLE_ADAPTER=any_cable \
  CABLE_URL=ws://localhost:8080/cable bin/rails s -p 3777
cd frontend && PORT=3777 node agent_browsers.mjs   # concurrent typing
PORT=3777 node agent_collab.mjs                     # rich text + cursors
```

## Stress test

```bash
# Boot the server with concurrency headroom first:
RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777

cd frontend && bun stress.mjs
# Crank it: CLIENTS=100 ROOMS=5 EDITS=80 KILLERS=12 LATE=10 CHURN=10 POLLERS=4 bun stress.mjs
```

A storm of concurrent clients edit shared documents at random offsets, with
late joiners, abrupt mid-traffic disconnects, clients that go offline, keep
editing, and reconnect (merging via the step1/step2 handshake), and HTTP pollers
hitting the `/content` endpoint the whole time. It checks byte-for-byte
convergence across every doc, including a fresh verifier that syncs from the
server alone, and exact character conservation: nothing lost, nothing applied
twice.

Token substrings are deliberately not asserted. Concurrent inserts at random
offsets in one Y.XmlText can legally interleave inside other clients' runs, so
conservation and convergence are the invariants that actually hold.

Reference run (M-series MacBook, 16 Puma threads and 16 cable workers): 100
clients, 8,800 edits, ~360k cable messages, 41k concurrent `/content` reads, all
103 docs byte-identical, zero errors.

## Production notes

- Provide durable `on_load` and `on_change` hooks. The durable store is the
  source of truth; channel instances are stateless per message.
- Use a shared cable adapter such as Redis or solid_cable for multi-process
  deployments.
- `config.action_cable.disable_request_forgery_protection` is on in development
  so the e2e script can connect without an Origin header.
