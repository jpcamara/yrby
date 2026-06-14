# yrb-lite ActionCable Demo

A collaborative Tiptap editor backed by Rails + ActionCable, with **no Node
server** — the Y.js sync protocol and awareness (shared cursors/presence) are
handled natively in Ruby by [yrb-lite](../..).

```
Browser (Tiptap + Yjs) ⇄ ActionCable ⇄ DocumentChannel (YrbLite::Sync)
```

The server is also a first-class reader of the document:
`GET /docs/:id/content` returns the live ProseMirror JSON, extracted from the
CRDT natively (`YrbLite::ProseMirrorExtractor`) — no headless browser, no JS.

## Run it

```bash
bundle install

# Build the frontend bundle (requires bun)
cd frontend && bun install && bun run build && cd ..

bin/rails s
```

Open http://localhost:3000 in **two windows** and type. You'll see live text
sync and each other's cursors. Open http://localhost:3000/docs/demo/content
to watch the server's native view of the document.

## How it works

**Server** — [`app/channels/document_channel.rb`](app/channels/document_channel.rb)
is the entire integration:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::Sync

  def subscribed = sync_for(params[:id])
  def receive(data) = sync_receive(data)
  def unsubscribed = sync_clear_presence
end
```

One shared `YrbLite::Awareness` (document + presence) lives in memory per
document key. ActionCable's worker threads call into it concurrently — safe
because yrb-lite's native types are `Send + Sync` and release the GVL during
CRDT work. Add `on_load`/`on_save` callbacks to persist documents.

**Client** — [`frontend/src/provider.js`](frontend/src/provider.js) is a
~150-line Yjs provider that speaks the standard y-protocols binary messages
(base64-encoded) over an ActionCable subscription. Tiptap's Collaboration and
CollaborationCursor extensions plug into it like any other provider.

## End-to-end test

With the server running:

```bash
cd frontend && bun e2e.mjs
```

Two simulated clients connect over raw WebSockets and assert: late-joiner
catch-up via the server, bidirectional live updates, awareness propagation,
byte-for-byte CRDT convergence, the server-side extraction endpoint, and
prompt presence reaping when a client disconnects (only the departed client's
cursor is cleared, well under the client-side timeout).

## Authoritative audit mode

Boot with `AUDIT=1` and the channel records every change durably — in a
single total order, *before* it is applied or broadcast — via yrb-lite's
`on_change` hook (see [`app/lib/audit_log.rb`](app/lib/audit_log.rb), an
fsync'd append-only log). `GET /docs/:id/audit` returns the log as base64
CRDT deltas.

```bash
AUDIT=1 RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777

cd frontend && bun audit.mjs
```

A client makes a series of edits; the test then fetches the audit log,
replays it into a fresh `Y.Doc` with **no** help from the live server, and
asserts the result matches the server's live document byte-for-byte — i.e.
the recorded log is a complete, authoritative history. (Storing before
distributing means a synchronous durable write per change; that's the
trade-off you opt into with `on_change`.)

For the hostile cases, `bun audit_scenarios.mjs` drives a fault-injectable
store (slow / failing, via `POST /docs/:id/audit/control`) across multiple
real clients and asserts the core guarantee — **no one else sees a change
until it's stored** — under:

1. **Slow store** — mid-store, no other client sees the change: not via live
   broadcast, not via `GET /content`, and not via a fresh client's resync
   (the back door). After the store completes, everyone converges and it's
   logged.
2. **Store failure** — a failed store leaks nothing to anyone and is absent
   from the log (the originating client keeps its optimistic edit, diverged).
3. **Self-heal** — after a failure, the client reconnects and re-offers the
   change; the recovered store records it and everyone converges.
4. **Offline catch-up** — edits made offline are recorded (as one merged
   diff) when the client reconnects, before others see them.

## Hostile input (chaos)

```bash
AUDIT=1 bin/rails s -p 3777
cd frontend && bun chaos.mjs
```

A vandal client sprays malformed frames — bad base64, random bytes,
truncated / oversized / multi-message / unknown-type protocol messages,
spoofed awareness, broken envelopes — while good clients edit. Asserts the
server stays up, the good clients still converge byte-for-byte, a second room
is untouched, and (in audit mode) the garbage is never logged as a change.
Malformed or multi-message frames are dropped before they can be processed or
relayed, so one bad client can't disrupt the others.

## Crash recovery

```bash
AUDIT=1 bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=write bun crash_recovery.mjs
# ... kill -9 the server, then restart it ...
AUDIT=1 bin/rails s -p 3777
cd frontend && ROOM=crash-1 PHASE=verify bun crash_recovery.mjs
```

Because audit mode records every change (fsync) *before* it's applied or
broadcast, every acknowledged edit is on disk when the server dies. After a
hard `kill -9` and restart, `on_load` replays the log (`AuditLog.replay`,
tolerant of a torn final line from a crash mid-append) and the document is
whole — no loss window, unlike a server that persists on a debounce.

## Stress test

```bash
# Boot the server with concurrency headroom first:
RAILS_MAX_THREADS=16 CABLE_WORKERS=16 bin/rails s -p 3777

cd frontend && bun stress.mjs
# Crank it: CLIENTS=100 ROOMS=5 EDITS=80 KILLERS=12 LATE=10 CHURN=10 POLLERS=4 bun stress.mjs
```

A storm of concurrent clients editing shared documents at random offsets,
with late joiners, abrupt mid-traffic disconnects, clients that go offline /
keep editing / reconnect (merging via the step1/step2 handshake), and HTTP
pollers hammering the extraction endpoint throughout. Asserts byte-for-byte
convergence across every doc (including a fresh verifier that syncs from the
server alone) and exact character conservation — nothing lost, nothing
applied twice.

Note: token *substrings* are deliberately not asserted — concurrent inserts
at random offsets in one Y.XmlText legally interleave inside other clients'
runs. Conservation + convergence are the correct invariants.

Reference run (M-series MacBook, 16 Puma threads / 16 cable workers):
100 clients, 8,800 edits, ~360k cable messages, 41k concurrent extraction
reads — all 103 docs byte-identical, zero errors.

## Production notes

- Documents are held in memory per-process. The async cable adapter (and this
  registry) assume a single server process; for multi-process deployments
  you'd pin documents to a process or persist via `on_load`/`on_save`.
- `config.action_cable.disable_request_forgery_protection` is enabled in
  development so the e2e script can connect without an Origin header.
