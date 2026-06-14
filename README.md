# YrbLite

Simple Ruby bindings for y-crdt via Rust, implementing the y-websocket sync protocol.

This gem provides minimal functionality needed to synchronize Y.js documents between clients using ActionCable or similar WebSocket solutions.

## Features

- **Built on yrs**: Uses the official Rust y-crdt implementation
- **Complete sync protocol**: Full y-websocket protocol support via `yrs::sync`
- **Awareness support**: User presence/cursor state management
- **Actually thread-safe**: share `Doc`/`Awareness` across Ruby threads — see [Thread Safety](#thread-safety)
- **ProseMirror extraction**: Read ProseMirror/Tiptap editor content from Y.Doc updates without JavaScript

## Installation

### Prerequisites

- Rust toolchain (install from https://rustup.rs)
- Ruby 3.0+

### Setup

```bash
bundle install
rake compile
```

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

`YrbLite::Sync` is a channel concern that implements the full y-websocket
protocol (document sync + awareness/presence) over ActionCable:

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::Sync

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
    sync_clear_presence
  end
end
```

It keeps one shared `YrbLite::Awareness` per document key (creation is
mutex-serialized; everything after runs lock-free on the thread-safe native
types), answers SyncStep1s directly, relays document and awareness changes
to other subscribers without echoing them back to the sender, and calls
`on_save` after every message that modified the document.

`sync_unsubscribed` (from `unsubscribed`) does two things: clears this
connection's presence (so a dropped socket or closed tab doesn't leave a
stale cursor until the client-side timeout reaps it), and — when the last
subscriber for a document leaves — persists and unloads the document from
memory, so a long-running server doesn't accumulate every document it has
ever served. Unloading only happens when an `on_load` is configured (so the
document can be brought back); otherwise the in-memory copy is kept.

**Hostile input is handled defensively.** Every incoming frame is validated
as exactly one well-formed protocol message before it is processed or
relayed; malformed, truncated, multi-message, oversized, or unknown frames
are dropped. So a malicious client can't crash the server (a Rust panic is
caught at the FFI boundary and surfaced as a Ruby exception, never a process
death) or relay garbage that disrupts the other clients in a room.

Messages are the standard y-protocols binary messages, base64-encoded as
`{ "m" => "<base64>" }`. A complete working example — Rails app, Tiptap
editor, custom browser-side `ActionCableProvider`, and an automated
end-to-end test — lives in
[`examples/actioncable-demo`](examples/actioncable-demo).

#### Authoritative audit mode (record before distribute)

By default a change is applied and broadcast immediately (fast path). If you
need to **durably record every change before anyone else sees it** — for
auditing, or to guarantee nothing is distributed until it's stored — register
an `on_change` recorder:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::Sync

  on_change do |key, update|
    # Synchronous, durable write. `update` is the exact CRDT delta.
    AuditLog.append!(key, update)   # raise to REJECT the change
  end

  def subscribed = sync_for(params[:id])
  def receive(data) = sync_receive(data)
  def unsubscribed = sync_clear_presence
end
```

With `on_change` registered, document changes take the strict path:

1. **Record** the change (the raw CRDT update delta) — synchronously.
2. **Apply** it to the shared document — only after it's recorded.
3. **Broadcast** it to other subscribers — only after it's applied.

The whole sequence runs under a per-document lock, so a document's changes
are recorded in a **single total order that matches the order they're
applied** — the recorded log is authoritative. If the recorder raises (e.g.
the store is unavailable), the change is **rejected**: not applied to the
document, not sent to anyone. Replaying the recorded deltas in order onto a
fresh `Y.Doc` reconstructs the document exactly. (The cost is the one you're
asking for: a synchronous durable write per change serializes that document's
writes. Different documents use different locks and proceed in parallel.)

`on_change` and `on_save` are independent — `on_save` snapshots the whole
document opportunistically; `on_change` is the per-change authoritative log.
The demo's `AUDIT=1` mode (see [`examples/actioncable-demo`](examples/actioncable-demo))
wires this to an fsync'd append-only log and proves, end to end, that the log
alone rebuilds the document.

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

### ProseMirror Content Extraction

Extract ProseMirror/Tiptap editor content from Y.Doc data without JavaScript.
The conversion runs natively in the Rust extension, reading the same CRDT
structures y-prosemirror reads in the browser:

```ruby
# From a raw binary update
content = YrbLite::ProseMirrorExtractor.extract(update_bytes)
# => {"type" => "doc", "content" => [...]}

# From a Doc
content = YrbLite::ProseMirrorExtractor.extract_from_doc(doc)

# Specify the XML fragment name (defaults to trying "prosemirror", "default", "doc")
content = YrbLite::ProseMirrorExtractor.extract(update_bytes, fragment: "prosemirror")
```

See [docs/PROSEMIRROR.md](docs/PROSEMIRROR.md) and [docs/ACCURACY.md](docs/ACCURACY.md)
for the research behind the ProseMirror <-> Y.Doc mapping.

## Thread Safety

Unlike the official `y-rb` gem, yrb-lite is safe to share across Ruby threads —
a `Doc` or `Awareness` can be used concurrently from Puma workers, ActionCable
connection threads, or background jobs without external locking.

Why this is true by construction, not by accident:

- **`yrs::Doc` is `Send + Sync`.** Every operation acquires the document's
  internal RwLock with *blocking* semantics (`read_blocking`/`write_blocking`),
  so concurrent access serializes instead of erroring or corrupting state.
- **`yrs::sync::Awareness` is designed for multi-threaded servers** — client
  states live in a concurrent map (`DashMap`) and the whole API is `&self`.
- **No interior-mutability hacks in the extension.** There is no `RefCell`
  (whose re-entrant borrow would panic and kill the Ruby process). Every native
  method opens and closes its transaction within a single call — no lock or
  borrow is ever held across calls, so there is nothing to deadlock on.
- **Compile-time enforcement**: `lib.rs` contains a `Send + Sync` static
  assertion for both wrapped types. If a future yrs upgrade regressed this,
  the gem would fail to build rather than silently become thread-unsafe.

`test/thread_safety_test.rb` exercises shared docs, the full sync handshake,
fan-in sync, awareness state, and ProseMirror extraction from 8 threads
concurrently and asserts CRDT convergence is unaffected by interleaving.

### True Parallelism (GVL Release)

Every method that does real CRDT work (applying updates, encoding state,
handling sync messages, ProseMirror extraction) releases Ruby's Global VM
Lock (`rb_thread_call_without_gvl`) while the native code runs. That means:

- **Heavy CRDT operations run in parallel across Ruby threads** — on MRI,
  not just JRuby/TruffleRuby. `bench/parallelism_bench.rb` shows >2x
  wall-clock speedup running concurrent extractions of a ~900 KB document
  update (GVL-held native code can never beat serial time).
- **A slow operation can't stall the VM.** A thread applying a large update
  holds the doc's internal write lock *without* holding the GVL, so other
  Ruby threads keep running instead of queueing behind it.

The pattern inside each method: copy the Ruby byte string, release the GVL,
do all yrs work (acquiring and releasing the doc lock entirely inside the
closure), reacquire the GVL, then build Ruby result objects. No Ruby API is
touched without the GVL, and no doc lock is ever held across a GVL
boundary — so the lock ordering is deadlock-free by construction. Panics in
native code are caught and re-raised as Ruby exceptions.

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
