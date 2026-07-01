# yrby

[![CI](https://github.com/jpcamara/yrby/actions/workflows/ci.yml/badge.svg)](https://github.com/jpcamara/yrby/actions/workflows/ci.yml)

Collaborative editing for Rails, backed by [y-crdt](https://github.com/y-crdt/y-crdt)
(the Rust library behind Y.js). Your Rails server speaks the y-websocket sync
protocol directly, so there's no separate Node process hosting the Y.js
documents.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable::Sync

  on_load   { |key|         MyStore.load(key) }
  on_change { |key, update| MyStore.append(key, update) }

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])
end
```

On the browser, use the `ActionCableProvider` from the 
[`yrby-client`](https://www.npmjs.com/package/yrby-client) npm package.
Integrates with any editor that includes Y.js support, such as Tiptap, ProseMirror
and [Lexxy](https://www.npmjs.com/package/lexxy-realtime).

## Usage

Install the gem and npm package:

```
gem install yrby-actioncable # depends on yrby
npm install yrby-client
```

## What you get

- A thread-safe Ruby `Doc` you can share across Ruby threads/fibers, and native CRDT work
  runs with the GVL released.
- The y-websocket protocol (document sync plus awareness/presence) as a
  one-include ActionCable concern.
- Authoritative record-before-distribute semantics: each document change can be
  recorded durably before it goes out to anyone.
- Optional server-side reads: `Doc#read_text` and `Doc#read_map` reconstruct a
  document's contents in Ruby - no Node process - for search, exports, validation,
  or server-side rendering.

## Scope

`yrby` binds just the part of `y-crdt` you need to *sync and persist* collaborative
documents - a `Doc`, awareness, and the y-websocket protocol primitives. By default
the Ruby side treats a document as opaque CRDT state: it applies updates, answers
sync handshakes, and records deltas without reaching into the contents - the browser
editor owns the document's shape. When you do need to look inside, `Doc#read_text`
and `Doc#read_map` reconstruct it server-side, in Ruby.

## Durability and delivery

The surface is intentionally small, but the focus is durability, resiliency, delivery
guarantees, correctness, and thread safety.

Towards that goal, `yrby` adds capabilities that stand out even in the Yjs ecosystem:

- Built-in update acknowledgement: the `ActionCableProvider` in `yrby-client` will continue to
  send updates until an ack is received from the server. [`yrby-actioncable`](https://rubygems.org/gems/yrby-actioncable)
  only sends an ack when applying an update is successful. The goal is at-least-once delivery,
  and because CRDTs are idempotent a duplicate update is effectively a no-op.
- Gap detection in document updates: before applying an update and sending an ack to the client,
  `yrby` checks whether the update results in any causal gap. Ie, an update comes through
  which depends on a previous update that is not yet present in the document. This can result in
  a document stuck with "pending" updates, which will _never_ apply if the missing update is not sent.
  To avoid this, `yrby` does not apply the update, and starts a new y-protocol sync with the client.
  That will cause the client to synchronize its document with the server, sending through any updates
  that may have been missed

## What about [yrb](https://github.com/y-crdt/yrb)?

`yrb` has a much larger interface that gives you most of the Yjs type system - 
shared text, arrays, maps, XML - to build and query documents in Ruby. It was a great
inspiration for my use of Yjs in Ruby/Rails, and I originally considered building
on top of it. There are a few reasons I went with `yrby` instead:

- `yrb` is largely unmaintained. It was built as an experiment for GitLab, and the original
  author mostly moved onto other projects.
- [It isn't thread-safe](https://github.com/y-crdt/yrb/issues/72). It segfaults in a threaded
  environment (such as ActionCable...)
- It's a much larger set of features to maintain, which most people don't need. The vast
  majority of people manipulate Y.js documents in the browser, not from a server-side language.

## Testing

Ruby and Rust unit tests cover the core. CI also runs the npm client tests and a
Rails demo smoke slice against the real ActionCable stack. The demo includes
heavier local suites for hostile input, crash recovery, multi-browser editing,
AnyCable, and load testing. The benchmark note below is from a single laptop.
Issues and PRs are welcome.

## Install

```ruby
# Core CRDT + protocol primitives:
gem "yrby"

# For the Rails/ActionCable server concern (Y::ActionCable::Sync):
gem "yrby-actioncable"
```

Requires Ruby 3.4 or newer. The release workflow builds precompiled gems for
Ruby 3.4 and 4.0 across the supported Ruby platforms, with native smoke tests
on Linux x86_64 and macOS arm64. Installing from a matching platform gem needs
no Rust; a source build needs [Rust](https://rustup.rs).

To work on the gem itself:

```bash
git clone https://github.com/jpcamara/yrby
cd yrby
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
require "y"

# Create docs
doc = Y::Doc.new        # random client ID
doc = Y::Doc.new(12345) # specific client ID (used for CRDT identity)

# Encoding
doc.encode_state_vector           # => current state vector
doc.encode_state_as_update        # => full update (lossless: keeps pending)
doc.encode_state_as_update(sv)    # => update diff against state vector
doc.compacted_state_update        # => full update, gap-free (excludes pending)

# Applying updates
doc.apply_update(update_bytes)    # apply raw V1 update
doc.pending?                      # => true if holding un-integrable pending structs

# Sync protocol
doc.sync_step1                    # => SyncStep1 message (this doc's state vector)
doc.handle_sync_message(data)     # => [msg_type, sync_type, response]; answers a
                                  #    peer's SyncStep1 with an integrated-only
                                  #    SyncStep2 (never serves pending structs)
```

### Pending structs and gap-free state

If a doc applies an update whose causally-prior update is missing (a "gappy"
update), yrs parks it as a **pending** struct: the integrated state vector stays
empty, but the pending block is held as a recovery buffer and heals if the
missing dependency later arrives. `Doc#pending?` reports this.

Pending structs are *not* document state, so they must not cross the sync
boundary — a peer that receives one can't integrate it and gets stuck. Two
guarantees keep serving safe:

- `handle_sync_message` answers `SyncStep1` with **integrated-only** state, so a
  server never serves a struct it can't integrate itself (this is automatic).
- `Doc#compacted_state_update` gives you the same gap-free full-state update for
  when you persist or hand off state yourself. It's non-destructive (the doc
  keeps its pending), while `encode_state_as_update` stays lossless so you can
  still preserve the raw pending bytes for recovery.

### Protocol codec (module functions)

Classifying and unwrapping wire frames is stateless, so it's exposed as
`Y` module functions rather than a class. The server never holds presence
or document state to route a frame — presence lives in the browser clients, and
the server only relays awareness frames opaquely.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta carried by a frame, or nil
Y.wrap_update(update_bytes)   # => wrap a raw doc update as a sync Update frame
```

### ActionCable Integration

`Y::ActionCable::Sync` (from the `yrby-actioncable` gem) is a channel
concern that implements the full y-websocket protocol (document sync +
awareness/presence) over ActionCable:

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable::Sync

  on_load { |key| MyStore.load(key) }                 # source of truth
  on_change { |key, update| MyStore.append(key, update) } # durable record

  def subscribed
    sync_subscribed params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end
end
```

The concern is store-backed. A handshake is answered from `on_load`; document
changes are checked against that durable state, recorded through `on_change`,
then broadcast. Nothing authoritative is kept in ActionCable process memory, so
AnyCable RPC workers, Puma workers, and separate dynos can all handle messages
for the same document as long as they share the same store and cable adapter.

`on_load` and `on_change` are required. If either is missing, the channel fails 
before it can acknowledge or broadcast edits. Presence is ephemeral:
awareness frames are relayed, and `yrby-client` sends a best-effort
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
- **An unhealable gap is dropped, not resynced forever.** A resync heals a gap
  whose missing dependency is still in flight. But a *permanently*-orphaned update
  (its dependency is gone for good) stays gappy through every resync, and a client
  retransmitting it would loop endlessly (server resyncs → client resends →
  repeat). After `gap_strike_limit` rejections of the same update on one
  connection (default 3, minimum 2), the channel settles it with
  `{ "ack" => id, "dropped" => true }` and drops it instead of resyncing again —
  breaking the loop while never dropping a *healable* gap (those heal within a
  resync or two, and healing frees the strike). The `dropped` flag lets the
  client surface the loss (`yrby-client` reports it via `onError`) instead of
  silently showing synced. Set `gap_strike_limit nil` to disable. Works on both
  transports: plain ActionCable keeps strikes on the channel instance; under
  AnyCable (fresh instance per RPC command) they persist through
  anycable-rails' `state_attr_accessor` (istate), declared automatically when
  anycable-rails is loaded.
- **`on_change` is at-least-once, and the durable guarantee is that replaying the
  log reconstructs the document.** Every update triggers `on_change` before it's acked or
  broadcast (record-before-distribute). If exactly-once updates matter for you, **you
  must make `on_change` idempotent**. But remember that the CRDT can handle duplicates.
- **A raising `on_change` rejects the update implicitly.** If the block raises,
  the update is neither acked nor broadcast (record-before-distribute stops both).
  There is no negative-ack: the client simply never receives the ack, keeps the
  update pending, and retransmits on its timer/reconnect. This is built for
  *transient* failures (the store is briefly down → a retry lands). A block that
  raises *deterministically* — a validation that always fails for this edit —
  will be retried forever, since nothing tells the client to stop. Enforce hard
  rejections before the edit reaches `on_change` (channel authorization in
  `subscribed`), not by raising inside it.
- **An over-cap frame is dropped the same silent way.** A frame larger than
  `max_frame_bytes` (default 8 MiB) is dropped before decoding — no ack, no
  broadcast — to bound the work a client can force. For a genuine document
  update that means the same implicit rejection as above: unacked, retransmitted
  forever. Normal typing never approaches the cap, but a large paste, an embedded
  image, or a big initial `SyncStep2` can. The drop is logged (`warn` for
  over-cap, `debug` for undecodable) with the document key and update id so it's
  findable; override `sync_log_context` on the channel to add a user/connection
  id. Size the cap for your largest expected payload, and reject
  genuinely-too-big content upstream rather than relying on the cap to reject it
  gracefully.

#### Multi-process deployments

Most Rails apps run several processes, and any of them might serve a given document. 
Two pieces keep them in step.

Broadcasts cross processes through the Action Cable adapter, so it needs to something
like `redis` or `solid_cable`, not `async`. With that in place, a change
on one process reaches clients on all of them.

Every process rebuilds document state from the durable store through `on_load`.
Because changes are recorded before broadcast, record-before-distribute holds
across processes: whichever process receives a change records it to the shared
store before anyone, anywhere, sees it.

`bun multiprocess.mjs` in the demo runs clients across two processes and checks
convergence, fresh reads on both, presence across processes, and one shared log.

##### AnyCable

`yrby` fully supports AnyCable.

The demo checks this against a real anycable-go + RPC server
(`frontend/anycable_probe.mjs`, `anycable_concurrent.mjs`): liveness, the
yrby client provider, cross-process reads, and concurrent convergence.

##### Demo

[`examples/actioncable-demo`](examples/actioncable-demo) is a full Rails + Tiptap
app using the yrby provider, with end-to-end tests.

#### Record Before Distribute

Every document change is handed to the `on_change` handler before broadcasting.
It is up to you to durably record it:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable::Sync

  # ...

  on_change do |key, update|
    # Synchronous, durable write. `update` is the exact CRDT delta.
    AuditLog.append!(key, update)   # raise to REJECT the change
  end

  # ...
end
```

If the recorder raises (say the store is down), the change is rejected: not
applied, not sent to anyone. The cost is a synchronous durable write on the path
of every change. There's no in-gem per-document lock; concurrent writes to one
document can both record (at-least-once), and since CRDT apply is idempotent a
duplicate record replays to the same document.

The demo wires `on_change` to a durable Postgres-backed log by default, and checks
end to end that the log alone rebuilds the document.

#### Reliable delivery (acks)

yrby document delivery is ack-tracked. Browser document updates carry an
`"id"`, and the server replies `{ "ack": <id> }` once `on_change` has succesfully fired.
A causally-gapped update is not acked; the server sends a resync request, and
the client keeps the update queued until it lands.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # update accepted; safe to forget
```

`yrby-client`'s `ActionCableProvider` handles this automatically. It keeps
the unacknowledged local document tail in a queue and sends the merged tail as a
single causally-complete delta. The id is the highest sequence in the batch, so
one `{ ack: id }` cumulatively confirms everything up to it. Because CRDT apply
is idempotent, a resend that already landed is a harmless no-op that just
re-acks. Awareness stays ephemeral and is not acked.

Presence (cursors, selections) is owned by the browser clients — the server
never sets or holds presence state, it only relays awareness frames opaquely.
See `yrby-client` for the client-side awareness API.

## Thread Safety

A `Doc` is safe to share across Ruby threads — used concurrently from Puma
workers, ActionCable connection threads, or background jobs without external
locking.

`test/thread_safety_test.rb` runs shared docs, the full sync handshake, and
fan-in sync across 8 threads at once, and checks the interleaving doesn't change
convergence.

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
Y::MSG_SYNC            # 0 - Document sync messages
Y::MSG_AWARENESS       # 1 - User presence data

Y::MSG_SYNC_STEP1      # 0 - State vector request
Y::MSG_SYNC_STEP2      # 1 - Update response
Y::MSG_SYNC_UPDATE     # 2 - Incremental update
```

## Sync Flow

```
Client A                          Server
   |                                  |
   |-------- connect() ------------->|
   |  (SyncStep1 + Awareness)        |
   |                                  |
   |<--- handle_sync_message resp ---|
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
