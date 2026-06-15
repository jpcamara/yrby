# yrb-lite ActionCable Demo

A collaborative Tiptap editor backed by Rails and ActionCable, with no Node
server. The Y.js sync protocol and awareness (shared cursors and presence) run
natively in Ruby through [yrb-lite](../..).

```
Browser (Tiptap + Yjs) ⇄ ActionCable ⇄ DocumentChannel (YrbLite::Sync)
```

The server can read the document too. `GET /docs/:id/content` returns the live
CRDT state (base64), pulled straight from the server's own Y.Doc with no
headless browser and no JS. Apply it to a fresh Y.Doc to see what the server
sees.

## Run it

```bash
bundle install

# Build the frontend bundle (requires bun)
cd frontend && bun install && bun run build && cd ..

bin/rails s
```

Open http://localhost:3000 in two windows and type. Text and cursors sync
between them. Open http://localhost:3000/docs/demo/content to watch the
server's own view of the document.

## How it works

On the server, [`app/channels/document_channel.rb`](app/channels/document_channel.rb)
is the whole integration:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::Sync

  def subscribed = sync_for(params[:id])
  def receive(data) = sync_receive(data)
  def unsubscribed = sync_clear_presence
end
```

One shared `YrbLite::Awareness` (document plus presence) lives in memory per
document key. ActionCable's worker threads call into it concurrently, which is
safe because yrb-lite's native types are `Send + Sync` and release the GVL
during CRDT work. Add `on_load`/`on_save` callbacks to persist documents.

The client uses the standard [`@y-rb/actioncable`](https://www.npmjs.com/package/@y-rb/actioncable)
`WebsocketProvider`, not a hand-rolled one. yrb-lite's server speaks its wire
format: it accepts the provider's `{ update: ... }` envelope (and its own
`{ m: ... }`) and sends one protocol message per frame. Tiptap's Collaboration
and CollaborationCursor extensions plug into it directly.

```js
import { createConsumer } from "@rails/actioncable"
import { WebsocketProvider } from "@y-rb/actioncable"

const provider = new WebsocketProvider(ydoc, createConsumer(), "DocumentChannel", { id: documentId })
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

`bun provider_check.mjs` exercises the standard provider on its own: it drives
the real `@y-rb/actioncable` `WebsocketProvider` against the server for document
sync in both directions, presence, byte-for-byte convergence, and late-join.

### Real browser tests (Playwright)

These drive actual Chrome windows running the real bundle (Tiptap plus the
`@y-rb/actioncable` provider), the same stack a person uses. They run
`playwright-core` against system Chrome, so there's no Chromium download. Pass
`PORTS=3777,3778` to split browsers across two server processes.

```bash
bin/rails s -p 3777
cd frontend && bun multi_browser.mjs   # 4 browsers: round-trip, presence,
                                       # late-join, reload/reconnect, storm
bun four_browsers.mjs                  # 4 browsers typing at once, per-keystroke
                                       # accounting (incl. same-position storm)
```

`four_browsers.mjs` has each browser type its own digit at the same time, then
checks that every browser's document is identical and that every keystroke
survived (counted per contributor), including a round where all four type at the
same position. It's been run single-process and across two Redis-backed
processes.

## Durable store: Postgres or file

`AUDIT=1` wires yrb-lite's `on_load`/`on_change` to a durable store. Two are
included, selected by `STORE_KIND`:

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
bin/rails db:prepare   # creates yrb_lite_demo_development + document_changes
```

(`config/database.yml` defaults to the local socket as `$USER`.) `GET
/docs/:id/audit` returns the stored deltas (base64).

## Authoritative audit mode

Boot with `AUDIT=1` and the channel records every change durably, in a single
total order, before it's applied or broadcast, using yrb-lite's `on_change`
hook. `GET /docs/:id/audit` returns the log as base64 CRDT deltas.

```bash
AUDIT=1 RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777

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
AUDIT=1 bin/rails s -p 3777
cd frontend && bun chaos.mjs
```

A vandal client sprays malformed frames (bad base64, random bytes, truncated,
oversized, multi-message, and unknown-type protocol messages, spoofed
awareness, broken envelopes) while good clients edit. The test checks that the
server stays up, the good clients still converge byte-for-byte, a second room is
untouched, and in audit mode the garbage is never logged as a change. Malformed
or multi-message frames get dropped before they can be processed or relayed, so
one bad client can't disrupt the others.

## Crash recovery

```bash
AUDIT=1 bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=write bun crash_recovery.mjs
# ... kill -9 the server, then restart it ...
AUDIT=1 bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=verify bun crash_recovery.mjs
```

Audit mode fsyncs every change before it's applied or broadcast, so every
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

AUDIT=1 CABLE_ADAPTER=redis bin/rails s -p 3777 -P tmp/pids/s3777.pid &
AUDIT=1 CABLE_ADAPTER=redis bin/rails s -p 3778 -P tmp/pids/s3778.pid &

cd frontend && PORTS=3777,3778 bun multiprocess.mjs
```

Clients are split across the two processes. The test checks cross-process
convergence (byte-for-byte), that both processes' server-side replicas stay
current (server reads and a late joiner's handshake), cross-process presence,
and a single shared audit log with every change recorded exactly once.

Liveness rides the Redis cable adapter. Each process applies broadcasts that
originated elsewhere to its own in-memory replica (the CRDT merge is
idempotent), and the shared audit log is the source of truth for cold loads via
`on_load`. Each process appends to the same `tmp/audit` log with atomic
`O_APPEND`, so the audit history is global and record-before-distribute holds
across processes.

## AnyCable

AnyCable terminates WebSockets in a Go process and runs channel logic in a
separate Ruby RPC server, so the in-memory-replica backend doesn't fit.
`SYNC_BACKEND=store` switches the channel to the stateless, store-backed path,
where documents come from the audit log rather than process memory.

```bash
# 1) AnyCable RPC server (channel logic in Ruby)
AUDIT=1 SYNC_BACKEND=store CABLE_ADAPTER=any_cable bundle exec anycable

# 2) anycable-go (WebSocket server, :8080; brew install anycable-go)
anycable-go --host=127.0.0.1 --port=8080 --rpc_host=127.0.0.1:50051 \
  --broadcast_adapter=redis --redis_url=redis://localhost:6379/15

# 3) Rails HTTP (pages + /content), broadcasting via AnyCable
AUDIT=1 SYNC_BACKEND=store CABLE_ADAPTER=any_cable bin/rails s -p 3777

# Probe + concurrent storm (WS on anycable-go :8080, HTTP on Puma :3777):
cd frontend
WS_PORT=8080 HTTP_PORT=3777 bun anycable_probe.mjs
WS_PORT=8080 HTTP_PORT=3777 CLIENTS=6 bun anycable_concurrent.mjs
PORT=8080 bun provider_check.mjs   # the real @y-rb/actioncable provider
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
at anycable-go (`action_cable_meta_tag` emits it), then run the Playwright
suites against the Puma page port. The WebSockets go to anycable-go:

```bash
AUDIT=1 SYNC_BACKEND=store CABLE_ADAPTER=any_cable \
  CABLE_URL=ws://localhost:8080/cable bin/rails s -p 3777
cd frontend && PORTS=3777 bun multi_browser.mjs   # all scenarios
PORTS=3777 bun four_browsers.mjs                  # 4 browsers typing at once
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

- Documents are held in memory per-process. The async cable adapter (and this
  registry) assume a single server process; for multi-process deployments you'd
  pin documents to a process or persist via `on_load`/`on_save`.
- `config.action_cable.disable_request_forgery_protection` is on in development
  so the e2e script can connect without an Origin header.
