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
provider's Awareness instance, unless you supply your own.

## What you get

- Thread-safe Ruby wrappers for `Doc` and `Awareness`. You can share them
  across Puma threads; native CRDT work runs with the GVL released.
- The y-websocket protocol (document sync plus awareness/presence) as a
  one-include ActionCable concern.
- A store-backed mode for AnyCable and multi-process deployments.
- An optional authoritative mode that records each change durably before it
  goes out to anyone.

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
doc = YrbLite::Doc.new(12345) # specific client ID

# Get document info
doc.client_id  # => unique client identifier
doc.guid       # => document GUID

# Encoding
doc.encode_state_vector           # => current state vector
doc.encode_state_as_update        # => full update
doc.encode_state_as_update(sv)    # => update diff against state vector

# Applying updates
doc.apply_update(update_bytes)    # apply raw V1 update

# Sync protocol messages
doc.sync_step1                    # => SyncStep1 message (contains state vector)
doc.sync_step2(state_vector)      # => SyncStep2 message (contains update)
doc.handle_sync_message(data)     # => [msg_type, sync_type, response]
doc.encode_update_message(update) # => wrap update as sync Update message
```

### Awareness (Document + Presence)

```ruby
# Create awareness instances (each contains a Doc)
awareness = YrbLite::Awareness.new        # random client ID
awareness = YrbLite::Awareness.new(12345) # specific client ID

# Get document info
awareness.client_id  # => unique client identifier
awareness.guid       # => document GUID
```

### Handling Sync Messages

```ruby
# When connection opens, send initial sync messages
initial_message = awareness.start
# Send initial_message to peer via WebSocket

# When receiving messages from peer
response = awareness.handle(incoming_data)
# Send response back to peer if not empty
send_to_peer(response) unless response.empty?
```

### ActionCable Integration

`YrbLite::ActionCable::Sync` (from the `yrb-lite-actioncable` gem) is a channel
concern that implements the full y-websocket protocol (document sync +
awareness/presence) over ActionCable:

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  # Optional persistence:
  # on_load { |key| Document.find_by(key: key)&.content }
  # on_save { |key, update| Document.find_by(key: key)&.update!(content: update) }

  def subscribed
    sync_for params[:id]
  end

  def receive(data)
    sync_receive(data)
  end

  def unsubscribed
    sync_unsubscribed(params[:id])
  end
end
```

One `YrbLite::Awareness` is shared per document key. Creating it is
mutex-serialized. After that, native calls run with the GVL released: document
operations use yrs' internal document lock, and awareness mutations are
serialized by the wrapper mutex. The concern answers SyncStep1 directly, relays
document and awareness changes to the other subscribers (not back to the
sender), and calls `on_save` after any message that changed the document.

`sync_unsubscribed` clears the connection's presence, so a closed tab doesn't
leave a stale cursor hanging until the client-side timeout. It also unloads the
document from memory once the last subscriber disconnects, which keeps the
process from holding onto every document it ever served. That unload only
happens when `on_load` is set and the document can be reloaded later; without
it, the in-memory copy is the only one and stays put.

Incoming frames are validated as a single well-formed protocol message before
anything processes or relays them. Malformed, truncated, multi-message,
oversized, or unknown frames are dropped. A bad frame can't crash the process: a
Rust panic is caught at the FFI boundary and re-raised as a Ruby exception. And
no single client can relay garbage that breaks the others in a room.

#### Multi-process deployments

Most Rails apps run several processes (Puma workers, multiple dynos), and any of
them might serve a given document. Two pieces keep them in step.

Broadcasts cross processes through the Action Cable adapter, so it needs to be a
real one (`redis` or `solid_cable`, not `async`). With that in place, a change
on one process reaches clients on all of them.

Each process also keeps its own copy of the document and applies broadcasts from
the others. The merge is an ordinary CRDT apply, idempotent and
order-independent, which keeps server reads and new-client handshakes current on
every process. Each broadcast carries a per-process id (`Sync.process_id`) that
tells a process to skip its own.

A cold process (no copy yet) rebuilds from the durable store through `on_load`.
In authoritative mode the store is always current, since changes are recorded
before they go out. Record-before-distribute therefore holds across processes:
whichever process receives a change records it to the shared store before
anyone, anywhere, sees it.

`bun multiprocess.mjs` in the demo runs clients across two processes and checks
the lot: convergence, fresh copies on both, presence across processes, and one
shared log.

##### AnyCable (`sync_backend :store`)

The default backend keeps that warm in-memory copy and relies on a `stream_from`
block running in Ruby for each broadcast. AnyCable breaks both assumptions.
anycable-go delivers broadcasts outside Ruby, so the block never runs. Each RPC
gets a fresh channel instance, which means ivars set in `subscribed` are gone by
`receive`. And there's no fixed worker-to-document mapping to lean on.

`sync_backend :store` is the path for that: stateless per message, no warm
copy.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync
  sync_backend :store

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

#### Authoritative audit mode (record before distribute)

By default a change is applied and broadcast immediately (the fast path). If you
need to durably record every change before anyone else sees it, whether for
auditing or to guarantee nothing is distributed until it's stored, register an
`on_change` recorder:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::ActionCable::Sync

  on_change do |key, update|
    # Synchronous, durable write. `update` is the exact CRDT delta.
    AuditLog.append!(key, update)   # raise to REJECT the change
  end

  def subscribed = sync_for(params[:id])
  def receive(data) = sync_receive(data)
  def unsubscribed = sync_unsubscribed(params[:id])
end
```

With `on_change` registered, a change is recorded before it goes anywhere. The
recorder writes the raw CRDT delta synchronously; only then is the change
applied to the shared document and broadcast. The whole sequence runs under a
per-document lock, so every change to a document is recorded in the same order
it's applied. That's what makes the log authoritative. Replay the deltas onto a
fresh `Y.Doc` and you get the document back exactly.

If the recorder raises (say the store is down), the change is rejected: not
applied, not sent to anyone. The cost is a synchronous durable write per change,
which serializes that document's writes. Other documents use other locks and run
in parallel.

`on_change` and `on_save` are separate. `on_save` snapshots the whole document
when it gets a chance; `on_change` is the per-change log. The demo's `AUDIT=1`
mode (in [`examples/actioncable-demo`](examples/actioncable-demo)) wires
`on_change` to an fsync'd append-only log and checks, end to end, that the log
alone rebuilds the document.

#### Reliable delivery (acks)

yrb-lite document delivery is ack-tracked. Browser document updates carry an
`"id"`, and the server replies `{ "ack": <id> }` once the update has been
**accepted** -- recorded in audit mode, applied in fast mode. A causally-gapped
update is not acked; the server sends a resync request, and the client keeps the
update queued until it lands.

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

### User Awareness/Presence

```ruby
# Set local user state (cursor position, name, etc.)
awareness.set_local_state('{"user": {"name": "Alice", "color": "#ff0000"}}')

# Get local state
awareness.local_state  # => '{"user": {"name": "Alice", "color": "#ff0000"}}'

# Clear local state (e.g., when disconnecting)
awareness.clear_local_state

# Encode awareness update for broadcasting
update = awareness.encode_awareness_update
```

### Low-Level Access

```ruby
# Get state vector for manual sync
sv = awareness.encode_state_vector

# Get update diffed against a state vector
update = awareness.encode_state_as_update(remote_state_vector)

# Apply raw update to the document
awareness.apply_update(update_bytes)

# Wrap raw update data in a sync message
message = awareness.encode_update(update_bytes)
```

## Thread Safety

`Doc` and `Awareness` are safe to share across Ruby threads. A `Doc` or
`Awareness` can be used concurrently from Puma workers, ActionCable connection
threads, or background jobs without external locking.

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
