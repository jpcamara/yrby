# yrb-lite

[![CI](https://github.com/jpcamara/yrb-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/jpcamara/yrb-lite/actions/workflows/ci.yml)

Collaborative editing for Rails, backed by [y-crdt](https://github.com/y-crdt/y-crdt)
(the Rust library behind Y.js). Your Rails server speaks the y-websocket sync
protocol directly, so there's no separate Node process hosting the Y.js
documents.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  def subscribed   = sync_for(params[:id])
  def receive(data) = sync_receive(data)
  def unsubscribed = sync_unsubscribed(params[:id])
end
```

On the browser, use the `yrb-lite-client` `ActionCableProvider`. Tiptap,
ProseMirror, and BlockNote all sync through the `Y.Doc` you pass in and the
provider's Awareness instance.

## What you get

- A thread-safe Ruby `Doc` you can share across Puma threads; native CRDT work
  runs with the GVL released.
- The y-websocket protocol (document sync plus awareness/presence) as a
  one-include ActionCable concern.
- Store-backed ActionCable/AnyCable delivery for multi-process deployments.
- Authoritative record-before-distribute semantics: each document change is
  recorded durably before it goes out to anyone.

What it doesn't do: auth, read-only connections, rate limiting, webhooks,
metrics. Hocuspocus ships extensions for those; here you'd build them with
Rails.

## Testing

Ruby and Rust unit tests cover the core. CI also runs the npm client tests and a
Rails demo smoke slice against the real ActionCable stack. The demo includes
heavier local suites for hostile input, crash recovery, multi-browser editing,
AnyCable, and load testing. The benchmark note below is from a single laptop.
Issues and PRs are welcome.

## Install

```ruby
# Core CRDT + protocol primitives:
gem "yrb-lite"

# For the Rails/ActionCable server concern (YrbLite::ActionCable::Sync):
gem "yrb-lite-actioncable"
```

Requires Ruby 3.4 or newer. The release workflow builds precompiled gems for
Ruby 3.4 and 4.0 across the supported Ruby platforms, with native smoke tests
on Linux x86_64 and macOS arm64. Installing from a matching platform gem needs
no Rust; a source build needs [Rust](https://rustup.rs).

To work on the gem itself:

```bash
git clone https://github.com/jpcamara/yrb-lite
cd yrb-lite
bundle install
bundle exec rake compile test
```

The rest of the dev setup, plus the demo, is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Docs

- The ActionCable concern and a quickstart are [below](#actioncable-integration).
- [`examples/actioncable-demo`](examples/actioncable-demo): a runnable Rails +
  Tiptap app with collaborative cursors, the AnyCable setup, a Postgres store,
  and the test/load suites.
- [CHANGELOG.md](CHANGELOG.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Usage

### Doc (Low-Level Document Sync)

```ruby
require "yrb_lite"

# Create docs
doc = YrbLite::Doc.new        # random client ID
doc = YrbLite::Doc.new(12345) # specific client ID (used for CRDT identity)

# Encoding
doc.encode_state_vector           # => current state vector
doc.encode_state_as_update        # => full update
doc.encode_state_as_update(sv)    # => update diff against state vector

# Applying updates
doc.apply_update(update_bytes)    # apply raw V1 update

# Sync protocol
doc.sync_step1                    # => SyncStep1 message (this doc's state vector)
doc.handle_sync_message(data)     # => [msg_type, sync_type, response]; answers a
                                  #    peer's SyncStep1 with a SyncStep2
```

### Protocol codec (module functions)

Classifying and unwrapping wire frames is stateless, so it's exposed as
`YrbLite` module functions rather than a class. The server never holds presence
or document state to route a frame — presence lives in the browser clients, and
the server only relays awareness frames opaquely.

```ruby
YrbLite.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
YrbLite.update_from_message(frame)  # => the document delta carried by a frame, or nil
YrbLite.wrap_update(update_bytes)   # => wrap a raw doc update as a sync Update frame
```

### ActionCable Integration

`YrbLite::ActionCable::Sync` (from the `yrb-lite-actioncable` gem) is a channel
concern that implements the full y-websocket protocol (document sync +
awareness/presence) over ActionCable:

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  on_load { |key| MyStore.load(key) }                 # source of truth
  on_change { |key, update| MyStore.append(key, update) } # durable record

  def subscribed
    sync_for params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end

  def unsubscribed
    sync_unsubscribed(params[:id])
  end
end
```

The concern is store-backed. A handshake is answered from `on_load`; document
changes are checked against that durable state, recorded through `on_change`,
then broadcast. Nothing authoritative is kept in ActionCable process memory, so
AnyCable RPC workers, Puma workers, and separate dynos can all handle messages
for the same document as long as they share the same store and cable adapter.

`on_load` and `on_change` are required. If either is missing, the channel fails
closed before it can acknowledge or broadcast edits. Presence is ephemeral:
awareness frames are relayed, and `yrb-lite-client` sends a best-effort
presence-removal frame on disconnect/pagehide, with the client-side awareness
timeout as the fallback for abrupt disconnects.

Incoming frames are validated as a single well-formed protocol message before
anything processes or relays them. Malformed, truncated, multi-message,
oversized, or unknown frames are dropped. A bad frame can't crash the process: a
Rust panic is caught at the FFI boundary and re-raised as a Ruby exception. And
no single client can relay garbage that breaks the others in a room.

#### Delivery guarantees

The contract is the same at every scale — one process, or hundreds across many
servers:

- **The document always converges.** CRDT updates are commutative and
  idempotent, so out-of-order, duplicate, or concurrent delivery all converge to
  the same correct document. This needs no coordination and holds everywhere.
- **The durable log never goes gappy.** An update is recorded only once its
  causal dependencies are already in the store (checked against `on_load`); a
  causally-incomplete update triggers a resync instead, so the log always
  rebuilds cleanly.
- **`on_change` is at-least-once, and the durable guarantee is that replaying the
  log reconstructs the document.** Every change is recorded before it's acked or
  broadcast (record-before-distribute). Entry count is not 1:1 with edits: a
  best-effort check skips most lost-ack retries but isn't cross-process exact (a
  retry on another process can record the same update twice), and a resync can
  coalesce a client's un-acked tail into a single record. So **make `on_change`
  idempotent** if duplicate side effects would matter (a webhook, a counter) — a
  raw append-only delta log is naturally fine, since it replays to the same
  document either way.

There is deliberately no in-gem cross-process lock. One that only spanned a
single process would give exactly-once at small scale and silently degrade as
you scale out, so the guarantee is uniform instead. If you need exactly-once
*side effects*, enforce it in your store (a unique key on the update) or with
your own distributed lock — the gem stays storage-agnostic and assumes neither.

#### Multi-process deployments

Most Rails apps run several processes (Puma workers, multiple dynos), and any of
them might serve a given document. Two pieces keep them in step.

Broadcasts cross processes through the Action Cable adapter, so it needs to be a
real one (`redis` or `solid_cable`, not `async`). With that in place, a change
on one process reaches clients on all of them.

Every process rebuilds document state from the durable store through `on_load`.
Because changes are recorded before broadcast, record-before-distribute holds
across processes: whichever process receives a change records it to the shared
store before anyone, anywhere, sees it.

`bun multiprocess.mjs` in the demo runs clients across two processes and checks
convergence, fresh reads on both, presence across processes, and one shared log.

##### AnyCable

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  on_load  { |key| MyStore.load(key) }          # required: source of truth
  on_change { |key, update| MyStore.append(key, update) }  # required: record

  def subscribed   = sync_for(params[:id])
  def receive(data) = sync_receive(data, params[:id])   # pass the key each call
  def unsubscribed = sync_unsubscribed(params[:id])
end
```

- `stream_from` is registered without a block; anycable-go does the relaying.
- A handshake (SyncStep1) is answered from the store. Changes are recorded, then
  broadcast. Nothing is held in Ruby between calls, so any worker can handle any
  message.
- Document frames use the normal server path. Awareness/presence uses a
  separate awareness stream with AnyCable `whisper: true`, so cursor traffic can
  take the low-latency client-to-client path without bypassing document
  durability.
- Pass `params[:id]` into `sync_receive`/`sync_unsubscribed` so the document key
  survives AnyCable's per-command instances.
- The sender gets its own updates echoed back (no Ruby callback to filter them).
  That's a no-op, since applying an update twice does nothing.

The demo checks this against a real anycable-go + RPC server
(`frontend/anycable_probe.mjs`, `anycable_concurrent.mjs`): liveness, the
yrb-lite client provider, cross-process reads, and concurrent convergence.

The wire format is the standard y-protocols binary messages, base64-encoded in
the ActionCable envelope. yrb-lite uses one canonical document envelope,
`{ "update" => ... }`, and sends one message per frame.

```js
import { createConsumer } from "@anycable/web"
import { ActionCableProvider } from "yrb-lite-client"

const provider = new ActionCableProvider(ydoc, createConsumer(), "DocumentChannel", { id: docId })
provider.connect()
```

[`examples/actioncable-demo`](examples/actioncable-demo) is a full Rails + Tiptap
app using the yrb-lite provider, with end-to-end tests.

#### Record Before Distribute

Every document change is durably recorded before anyone else sees it. Register
an `on_change` recorder:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  on_change do |key, update|
    # Synchronous, durable write. `update` is the exact CRDT delta.
    AuditLog.append!(key, update)   # raise to REJECT the change
  end

  def subscribed = sync_for(params[:id])
  def receive(data) = sync_receive(data, params[:id])
  def unsubscribed = sync_unsubscribed(params[:id])
end
```

With `on_change` registered, a change is recorded before it goes anywhere. The
recorder writes the raw CRDT delta synchronously; only then is the change
broadcast. Replay the deltas onto a fresh `Y.Doc` and you get the document back
exactly.

If the recorder raises (say the store is down), the change is rejected: not
applied, not sent to anyone. The cost is a synchronous durable write per change,
which serializes that document's writes. Other documents use other locks and run
in parallel.

The demo wires `on_change` to a durable Postgres-backed log by default, with an
fsync'd file log available via `STORE_KIND=file`, and checks end to end that the
log alone rebuilds the document.

#### Reliable delivery (acks)

yrb-lite document delivery is ack-tracked. Browser document updates carry an
`"id"`, and the server replies `{ "ack": <id> }` once the update has been
**durably recorded**. A causally-gapped update is not acked; the server sends a
resync request, and the client keeps the update queued until it lands.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client    { "ack": 42 }     # update accepted; safe to forget
```

`yrb-lite-client`'s `ActionCableProvider` handles this automatically. It keeps
the unacknowledged local document tail in a queue and sends the merged tail as a
single causally-complete delta. The id is the highest sequence in the batch, so
one `{ ack: id }` cumulatively confirms everything up to it. Because CRDT apply
is idempotent, a resend that already landed is a harmless no-op that just
re-acks. Awareness stays ephemeral and is not acked.

Presence (cursors, selections) is owned by the browser clients — the server
never sets or holds presence state, it only relays awareness frames opaquely.
See `yrb-lite-client` for the client-side awareness API.

## Thread Safety

A `Doc` is safe to share across Ruby threads — used concurrently from Puma
workers, ActionCable connection threads, or background jobs without external
locking.

That comes from how the underlying types work, not from locking on top:

- `yrs::Doc` is `Send + Sync`. Every operation takes the document's internal
  RwLock with blocking semantics (`read_blocking`/`write_blocking`), so
  concurrent access serializes instead of erroring or corrupting state.
- `yrs::sync::Awareness` is `Send` but not `Sync` in the current yrs version,
  so the Ruby wrapper stores it in a `Mutex`. The mutex is always acquired
  inside the no-GVL native section and released before Ruby runs again.
- The extension uses no `RefCell`-style runtime borrows that could panic under
  re-entrancy. Each native method opens and closes its transaction or mutex
  guard inside one call.
- Static assertions in `lib.rs` prove `Doc` and `Mutex<Awareness>` are
  `Send + Sync`. If a yrs upgrade regressed either wrapper's thread-safety, the
  gem would fail to compile instead of quietly turning thread-unsafe.

`test/thread_safety_test.rb` runs shared docs, the full sync handshake, fan-in
sync, and awareness state across 8 threads at once, and checks the interleaving
doesn't change convergence.

### Parallelism (GVL release)

Every method that does real CRDT work (applying updates, encoding state,
handling sync messages) releases Ruby's Global VM Lock
(`rb_thread_call_without_gvl`) while the native code runs. That buys two things.

CRDT work runs in parallel across Ruby threads on MRI, not just
JRuby/TruffleRuby. `bench/parallelism_bench.rb` measures over 2x wall-clock
speedup applying a ~900 KB update concurrently; native code that held the GVL
couldn't beat serial time.

A slow operation also can't stall the VM. A thread applying a large update holds
the doc's write lock without holding the GVL, so other Ruby threads keep running
instead of queuing behind it.

Each method has the same shape: copy Ruby byte strings first, drop the GVL, do
the yrs work while taking and releasing native locks entirely inside the
closure, take the GVL back, then build Ruby objects. No Ruby API is touched
without the GVL, and no native lock is held while reacquiring it, so the lock
order can't deadlock. Panics in native code are caught and re-raised as Ruby
exceptions.

## Message Type Constants

```ruby
YrbLite::MSG_SYNC            # 0 - Document sync messages
YrbLite::MSG_AWARENESS       # 1 - User presence data
YrbLite::MSG_AUTH            # 2 - Authentication
YrbLite::MSG_QUERY_AWARENESS # 3 - Request awareness state

YrbLite::MSG_SYNC_STEP1      # 0 - State vector request
YrbLite::MSG_SYNC_STEP2      # 1 - Update response
YrbLite::MSG_SYNC_UPDATE     # 2 - Incremental update
```

## Sync Flow

```
Client A                          Server
   |                                  |
   |-------- start() --------------->|
   |  (SyncStep1 + Awareness)        |
   |                                  |
   |<------- handle() response ------|
   |  (SyncStep2)                    |
   |                                  |
   |  (Document synchronized!)        |
   |                                  |
   |<------- updates ----------------|
   |-------- updates --------------->|
```

## Development

```bash
# Setup
bundle install

# Build extension
rake compile

# Run tests
rake test

# Clean build artifacts
rake clean
```

## License

MIT License

## Acknowledgments

- [y-crdt/yrs](https://github.com/y-crdt/y-crdt) - The Rust implementation of Y.js
- [Magnus](https://github.com/matsadler/magnus) - Ruby bindings for Rust
- [rb-sys](https://github.com/oxidize-rb/rb-sys) - Rust extensions for Ruby
