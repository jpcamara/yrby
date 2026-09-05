# The document channel

## The one the gem ships

Most apps never write a channel. `Y::DocumentChannel` ships in `yrby-rails`,
the same way `Turbo::StreamsChannel` ships in turbo-rails. A client subscribes
with the signed grant that `collaborative_document_tag` rendered. The channel
looks up the record from the grant, and it records every change as
`Y::Document` rows before it acknowledges the change. A grant that is missing,
tampered with, or minted for a different attribute is rejected, and so is one
whose record has since been deleted. See
[Getting started](/docs/getting-started).

The rest of this page is about building your own channel with the same concern
`Y::DocumentChannel` uses. You'd do that for custom storage, for documents keyed
by room with no record behind them, or for an authorization scheme of your own.

## Build your own

`include Y::ActionCable` (from the `yrby-rails` gem) is the channel
integration. It implements the y-websocket protocol, document sync plus
awareness and presence, over Action Cable and AnyCable. A key names one
document. Shape it however your app thinks about documents: per record and
attribute (`post/42/body`), per room, per anything.

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  def subscribed
    sync_subscribed params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end

  private

  # Everyone is denied until you wire this to your app's auth:
  # sync_subscribed rejects the subscription unless it returns true.
  def authorized?(_document_key) = false
end
```

Storage defaults to the gem's `Y::Document` models. Declare the two hooks to
point it somewhere else:

```ruby
  on_load   { |key| Y::Document.load_state(key) }                # rebuild from storage
  on_change { |key, update| Y::Document.append(key, update) }    # record, then broadcast
```

## The two hooks

`on_load` and `on_change` default to `Y::Document` storage when the yrby-rails
models are installed. Declaring either one replaces the default. Outside a
yrby-rails app there is no default, and the channel fails before it can
acknowledge or broadcast an edit until you declare both.

`on_load` is called with a key and returns a binary Y.js update, or nil for a
fresh document. `on_change` is called with a key and the exact CRDT delta, and
its job is to record that delta. Both run in the channel instance's context
through `instance_exec`, so they can use anything the channel can: `params`,
`current_user`, whatever you have.

The concern is backed by your store. A handshake is answered from `on_load`.
Document changes go through `on_change` and are then broadcast. Nothing
authoritative is kept in Action Cable process memory, so AnyCable RPC workers,
Puma workers, and separate dynos can all handle messages for the same document,
as long as they share the same store and the same cable adapter.

Pass the key on every action (`sync_receive(data, params[:id])`). Under AnyCable
each RPC command gets a fresh channel instance, so an instance variable set in
`subscribed` is gone by the time `receive` runs.

## Authorization

`sync_subscribed` calls `authorized?(key)` before it opens a stream or serves
any state. The concern's default returns `false`. A channel that never defines
the method rejects every subscriber, and the rejection log says how to fix it.
The channel has to say yes explicitly.

Override the method with your app's real check. It runs in the channel, so the
connection's identity is available:

```ruby
private

def authorized?(key)
  current_user&.can_edit?(key)
end
```

A document that really is public gets an explicit `def authorized?(_key) =
true`. It's in the code, so a reviewer can grep for it. A subscriber that is
refused never reaches `receive`, because without a confirmed subscription the
cable routes nothing to the channel. One gate covers reads and writes.

For documents that belong to a record, the gem provides the token flow
`authorized?` needs: `Y::Collaborative`, which the engine includes into Active
Record. The page mints a signed GlobalID scoped to one attribute, and the
channel trades it back for the record. The client never names a document.

```erb
<%# the view names the document, signed %>
<%= tag.div data: { sgid: post.collaborative_sgid(:body) } %>
```

```ruby
# the channel trades the token back for the record
def authorized?(_key) = record.present? && record.editable_by?(current_user)
def record = @record ||= Y::Collaborative.locate(params[:sgid], :body)
```

A token minted for `:body` only verifies under `:body`'s purpose
(`"yrby/body"`). Tampered, expired, and wrong-attribute tokens locate nothing.

The same idea works without records. The live demos on this site sign the
document key itself with a `Rails.application.message_verifier`, because their
rooms are created lazily and there is no record to sign at render time. Their
`authorized?` accepts only what the token verifies to. That's a good fit when
subscribers are anonymous.

## Record before distribute

Every document change is handed to `on_change` before it is broadcast.
Recording it durably is your job.

```ruby
on_change do |key, update|
  # Synchronous, durable write. `update` is the exact CRDT delta.
  AuditLog.append!(key, update)   # raise to REJECT the change
end
```

If the recorder raises, the change is rejected: it isn't applied and it isn't
sent to anyone. The cost is a synchronous durable write on the path of every
change. There is no per-document lock in the gem, so two concurrent writes to
one document can both record (at least once). Applying a CRDT update twice is a
no-op, so that's fine.

## Delivery guarantees

The contract is the same at every scale, from one process to hundreds of them
across many servers.

**The document always converges.** CRDT updates are commutative and idempotent.
Out-of-order, duplicate, and concurrent delivery all end up at the same correct
document. This needs no coordination and holds everywhere.

**An acked update is durable, even one that arrived out of order.** An update
with a missing dependency is recorded and acked like any other, and it waits as
pending in the document. The missing dependency is an update some client still
holds unacked. That client keeps retransmitting it until the server records it,
and then the gap closes.

**`on_change` runs at least once, and the durable guarantee is that replaying
the log reconstructs the document.** Every update triggers `on_change` before
it is acked or broadcast. If you need exactly-once, make `on_change`
idempotent. The CRDT handles duplicates either way.

**A raising `on_change` rejects the update implicitly.** If the block raises,
the update is neither acked nor broadcast. There is no negative ack. The client
never gets the ack, keeps the update pending, and retransmits on its timer or
on reconnect. This is built for transient failures, where a retry lands. A
block that raises deterministically will be retried forever, because nothing
tells the client to stop. Enforce hard rejections before the edit reaches
`on_change`, in the channel's authorization at subscribe time. Don't raise
inside the hook for that.

**An over-cap frame is dropped the same silent way.** A frame larger than
`max_frame_bytes` (default 8 MiB) is dropped before decoding, with no ack and no
broadcast. That bounds the work a client can force. For a real document update
it means the same implicit rejection as above. Normal typing never gets near
the cap, but a large paste, an embedded image, or a big initial `SyncStep2`
can. The drop is logged with the document key and update id. Override
`sync_log_context` on the channel to add a user or connection id to that log
line.

## Frame validation

Incoming frames are validated as a single well-formed protocol message before
anything processes or relays them. Malformed, truncated, multi-message,
oversized, and unknown frames are dropped. A bad frame can't crash the process:
a Rust panic is caught at the FFI boundary and re-raised as a Ruby exception.
No single client can relay garbage that breaks the others in a room.

Validation is about shape, not volume. A client sending well-formed frames as
fast as it can is still a problem, and that's a job for a rate limit. This
site's own channel puts a token bucket in front of `sync_receive` for that
reason; see its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md).

## Reliable delivery (acks)

Document delivery is ack-tracked. Browser updates carry an `"id"`, and the
server replies `{ "ack": <id> }` once `on_change` has fired successfully.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # update accepted; safe to forget
```

`yrby-client`'s `ActionCableProvider` handles this for you. It keeps the
unacknowledged local tail in a queue and sends the merged tail as one causally
complete delta. The id is the highest sequence in the batch, so one ack
confirms everything up to it. A resend that already landed is a harmless no-op
that just gets acked again. Awareness is ephemeral and is not acked.

## Causal gaps

Yjs updates can arrive out of order. An update can reach the server before the
update it depends on. yrby treats that as normal. The update is recorded and
acked like any other, waits as a pending struct in the document, and
integrates on its own the moment the missing dependency lands. The write path
never rebuilds the document. It appends, relays, and acks, so a gapped update
costs the same as any other.

Serving is lossless too. `handle_sync_message` serves full state, pending
included, so a peer parks the same pending struct and heals it the same way.
Healing needs no special machinery. The missing dependency is an update its
sender still holds unacked, and at-least-once retransmission delivers it. Only
compaction excludes pending, because folding a log must not freeze an
un-integrable struct into the base state.

An open gap doesn't announce itself. The edit sits as pending, invisible in the
document, until its dependency arrives. The gap worth alerting on is one that
no live client can supply, and that is what the `on_gap` hook surfaces. It
fires with the document key whenever a document is loaded to serve state and a
gap is still open.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_gap { |key| StatsD.increment("yrby.gap", tags: ["doc:#{key}"]) }
end
```

Gaps are also logged at `info`. Errors raised in the hook are swallowed, so a
broken metrics call can't break frame handling.

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

Classifying and unwrapping wire frames is stateless, so these are module
functions on `Y`, with no object to construct. The server never holds presence
or document state to route a frame.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta carried by a frame, or nil
Y.wrap_update(update_bytes)   # => wrap a raw doc update as a sync Update frame
```
