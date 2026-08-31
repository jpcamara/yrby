# The document channel

`include Y::ActionCable` (from the `yrby-rails` gem) is the channel
integration: the y-websocket protocol, document sync plus awareness/presence,
over Action Cable and AnyCable.

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load   { |key| Y::Document.load_state(key) }                # rebuild from storage
  on_change { |key, update| Y::Document.append(key, update) }    # record, then broadcast

  def subscribed
    return reject unless authorized?(params[:id])

    sync_subscribed params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end

  private

  # Everyone is denied until you wire this to your app's auth.
  def authorized?(_document_key) = false
end
```

## The two hooks

`on_load` and `on_change` are required. If either is missing, the channel fails
before it can acknowledge or broadcast edits.

`on_load` is called with a key and returns a binary Y.js update, or nil for a
fresh document. `on_change` is called with a key and the exact CRDT delta, and
records it. Both run in the channel instance's context (`instance_exec`), so
they can use anything the channel can: `params`, `current_user`, whatever.

The concern is store-backed. A handshake is answered from `on_load`; document
changes are recorded through `on_change`, then broadcast. Nothing authoritative
is kept in Action Cable process memory, so AnyCable RPC workers, Puma workers,
and separate dynos can all handle messages for the same document as long as they
share the same store and cable adapter.

Pass the key on every action (`sync_receive(data, params[:id])`). Under AnyCable
each RPC command gets a fresh channel instance, so an instance variable set in
`subscribed` is gone by the time `receive` runs.

## Record before distribute

Every document change is handed to `on_change` before it is broadcast. It is up
to you to durably record it.

```ruby
on_change do |key, update|
  # Synchronous, durable write. `update` is the exact CRDT delta.
  AuditLog.append!(key, update)   # raise to REJECT the change
end
```

If the recorder raises, the change is rejected: not applied, not sent to anyone.
The cost is a synchronous durable write on the path of every change. There is no
in-gem per-document lock, so concurrent writes to one document can both record
(at-least-once); applying a CRDT update twice is a no-op.

## Delivery guarantees

The contract is the same at every scale, one process or hundreds across many
servers.

**The document always converges.** CRDT updates are commutative and idempotent,
so out-of-order, duplicate, or concurrent delivery all converge to the same
correct document. This needs no coordination and holds everywhere.

**An acked update is durable, even one that arrived out of order.** An update
with a missing dependency is recorded and acked like any other, and parks as
pending in the document. That missing dependency is an update some client still
holds unacked, so that client keeps retransmitting it until the server records
it, and the gap closes. The ack loop is the guarantee.

**`on_change` is at-least-once, and the durable guarantee is that replaying the
log reconstructs the document.** Every update triggers `on_change` before it is
acked or broadcast. If exactly-once matters for you, make `on_change`
idempotent. But remember the CRDT can handle duplicates.

**A raising `on_change` rejects the update implicitly.** If the block raises, the
update is neither acked nor broadcast. There is no negative ack: the client
never receives the ack, keeps the update pending, and retransmits on its
timer or reconnect. This is built for *transient* failures, where a retry lands.
A block that raises *deterministically* will be retried forever, because nothing
tells the client to stop. Enforce hard rejections before the edit reaches
`on_change` — channel authorization in `subscribed` — not by raising inside it.

**An over-cap frame is dropped the same silent way.** A frame larger than
`max_frame_bytes` (default 8 MiB) is dropped before decoding, with no ack and no
broadcast, to bound the work a client can force. For a genuine document update
that means the same implicit rejection as above. Normal typing never approaches
the cap, but a large paste, an embedded image, or a big initial `SyncStep2` can.
The drop is logged with the document key and update id; override
`sync_log_context` on the channel to add a user or connection id.

## Frame validation

Incoming frames are validated as a single well-formed protocol message before
anything processes or relays them. Malformed, truncated, multi-message,
oversized, or unknown frames are dropped. A bad frame can't crash the process: a
Rust panic is caught at the FFI boundary and re-raised as a Ruby exception. No
single client can relay garbage that breaks the others in a room.

Validation is about *shape*, not volume. A client sending well-formed frames as
fast as it can is still a problem, and that is a rate limit's job, not the
protocol's. This site's own channel puts a token bucket in front of
`sync_receive` for exactly that reason; see its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md).

## Reliable delivery (acks)

Document delivery is ack-tracked. Browser updates carry an `"id"`, and the
server replies `{ "ack": <id> }` once `on_change` has successfully fired.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # update accepted; safe to forget
```

`yrby-client`'s `ActionCableProvider` handles this automatically. It keeps the
unacknowledged local tail in a queue and sends the merged tail as a single
causally-complete delta. The id is the highest sequence in the batch, so one ack
cumulatively confirms everything up to it. A resend that already landed is a
harmless no-op that just re-acks. Awareness is ephemeral and is not acked.

## Causal gaps

Yjs updates can arrive out of order: an update can reach the server before
another update it depends on. yrby treats that as normal. The update is recorded
and acked like any other, parks as a pending struct in the document, and
integrates on its own the moment the missing dependency lands. The write path
never rebuilds the document; it appends, relays, and acks, so a gapped update
costs the same as any other.

Serving is lossless too. `handle_sync_message` serves full state, pending
included, so a peer parks the same pending struct and heals it the same way.
Healing needs no special machinery: the missing dependency is an update its
sender still holds unacked, and at-least-once retransmission delivers it. Only
compaction excludes pending, because folding a log must not freeze an
un-integrable struct into the base state.

An open gap is quiet. The edit sits as pending, invisible in the document, until
its dependency arrives. The gap worth alerting on is one no live client can
supply, and that is what the `on_gap` hook surfaces. It fires with the document
key whenever a document is loaded to serve state and a gap is still open.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_gap { |key| StatsD.increment("yrby.gap", tags: ["doc:#{key}"]) }
end
```

Gaps are also logged at `info`, and errors raised in the hook are swallowed so
observability can never break frame handling.

## Sync flow

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

## Message type constants

```ruby
Y::MSG_SYNC            # 0 - Document sync messages
Y::MSG_AWARENESS       # 1 - User presence data

Y::MSG_SYNC_STEP1      # 0 - State vector request
Y::MSG_SYNC_STEP2      # 1 - Update response
Y::MSG_SYNC_UPDATE     # 2 - Incremental update
```

## Protocol codec

Classifying and unwrapping wire frames is stateless, so it is exposed as `Y`
module functions rather than a class. The server never holds presence or
document state to route a frame.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta carried by a frame, or nil
Y.wrap_update(update_bytes)   # => wrap a raw doc update as a sync Update frame
```
