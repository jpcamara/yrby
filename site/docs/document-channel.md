# The document channel

## The one the gem ships

Most apps never write a channel. `Y::DocumentChannel` ships in `yrby-rails`,
as `Turbo::StreamsChannel` ships in turbo-rails. A client subscribes with the
signed grant that `collaborative_document_tag` rendered. The channel finds the
record from the grant and saves every change through that attribute's storage
before it acknowledges the change. It rejects a grant that is missing, tampered
with, expired, or signed for a different attribute, and one whose record has
been deleted. See [Getting started](/docs/getting-started).

By default, a valid grant is enough. To also check the connected user's
current permissions, register a block in `config.to_prepare`:

```ruby
# config/initializers/yrby.rb, inside Rails.application.config.to_prepare
Y::DocumentChannel.authorize_document do |record, name|
  current_user.present? && record.editable_by?(current_user, attribute: name)
end
```

The block runs in the channel, so `current_user` is available. `editable_by?`
is your app's method. yrby doesn't define it. If the block returns false or
nil, the channel rejects the subscription before it opens a stream or sends
any state.

The rest of this page covers building your own channel with the concern that
`Y::DocumentChannel` uses. You'd do that for documents keyed by room with no
record behind them, for a different store, or for your own authorization
scheme.

## Build your own

`include Y::ActionCable`, from the `yrby-rails` gem, adds the y-websocket
protocol to a channel: document sync, awareness, and presence, over Action
Cable or AnyCable. A key names one document. Pick whatever scheme fits your
app: one per record and attribute (`post/42/body`), one per room, or anything
else.

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  def subscribed = sync_subscribed(params[:id])

  def receive(data) = sync_receive(data, params[:id])

  private

  # This denies everyone until you wire it to your app's auth.
  # sync_subscribed rejects the subscription unless this returns true.
  def authorized?(_document_key) = false
end
```

Storage defaults to the gem's `Y::Document` models. Declare the two hooks to
point it somewhere else:

```ruby
  on_load   { |key| Y::Document.load_state(key) }                # read the document from storage
  on_change { |key, update| Y::Document.append(key, update) }    # save the change, then broadcast
```

`bin/rails generate yrby:install --channel` generates this channel for you.
Without `--channel`, the generator adds only the storage migration.

## The two hooks

When the yrby-rails models are installed and a channel declares neither hook,
both hooks use `Y::Document`. To use a different store, declare both. If you
declare only one, subscribing raises an error, so reads and writes can't end
up in different stores. A subclass can override one hook and inherit the other,
as long as the parent declares both. Outside a Rails app with yrby-rails there
are no defaults.

`on_load` receives a key and returns a binary Y.js update, or nil for a new
document. `on_change` receives a key and the CRDT delta, and it saves that
delta. Both run in the channel instance through `instance_exec`, so they can
call `params`, `current_user`, and any other channel method.

The concern reads and writes through your store. It answers each handshake
from `on_load`. It passes each document change to `on_change` and then
broadcasts it. Action Cable processes hold no document state in memory, so
AnyCable RPC workers, Puma workers, and separate dynos can all handle messages
for the same document. They need to share the store and the cable adapter.

Pass the key on every action: `sync_receive(data, params[:id])`. AnyCable
builds a new channel instance for each RPC command, so an instance variable
set in `subscribed` is gone by the time `receive` runs.

## Authorization

`sync_subscribed` calls `authorized?(key)` before it opens a stream or sends
any state. The concern's default returns `false`, so a channel that doesn't
define the method rejects every subscriber. The log line for each rejection
says how to fix it.

Define the method with your app's check. It runs in the channel, so the
connection's identity is available:

```ruby
private

def authorized?(key)
  current_user&.can_edit?(key)
end
```

For a public document, write `def authorized?(_key) = true`. Then the decision
is in the code, where a reviewer can find it.

`authorized?` runs once, when the client subscribes. The subscription is
authorized until it ends. To cut off access during a session, stop the
subscription yourself. Short grant lifetimes also help, because every new
subscription checks the grant again.

For documents that belong to a record, `Y::Collaborative` provides the token
that `authorized?` needs. The engine includes it in Active Record. The page
renders a signed GlobalID scoped to one attribute, and the channel looks up the
record from it. The client never names a document.

```erb
<%# the view picks the document and signs it %>
<%= tag.div data: { grant: post.collaborative_sgid(:body) } %>
```

```ruby
# the channel looks up the record from the token
def authorized?(_key) = record.present? && record.editable_by?(current_user)
# Not memoized: AnyCable builds a new channel instance for every command.
def record = Y::Collaborative.locate(params[:grant], :body)
```

A token signed for `:body` verifies only under the `"yrby/body"` purpose.
`locate` returns nil for a tampered, expired, or wrong-attribute token.

You can use the same approach without records. The live demos on this site
sign the room with `Rails.application.message_verifier`, because their rooms
are created on first use and there's no record to sign when the page renders.
Their `authorized?` accepts only the key the token verifies to. This works
well for anonymous subscribers.

## Record before distribute

The concern passes every document change to `on_change` before it broadcasts
the change. Your block saves it durably.

```ruby
on_change do |key, update|
  # Write synchronously and durably. `update` is the CRDT delta.
  AuditLog.append!(key, update)   # raising here rejects the change
end
```

If the block raises, the server rejects the change. It doesn't apply it or
send it to anyone. The cost is one synchronous write for every change. The gem
takes no per-document lock, so two concurrent writes to one document can both
be saved. Applying the same CRDT update twice has no effect, so the duplicate
is harmless.

## Delivery guarantees

These guarantees hold whether you run one process or hundreds across many
servers.

- The document always converges. CRDT updates are commutative and idempotent,
  so out-of-order, duplicate, and concurrent delivery all produce the same
  document. No coordination is needed.
- An acknowledged update is durable, including one that arrived out of order.
  The server saves and acknowledges an update with a missing dependency like
  any other, and the update waits as pending in the document. Some client
  still holds the missing update unacknowledged. That client resends it until
  the server saves it, and then the gap closes.
- `on_change` runs at least once for every update, before the server
  acknowledges or broadcasts it. Replaying what it saved rebuilds the
  document. If you need exactly-once behavior, make `on_change` idempotent.
  The CRDT handles duplicates either way.
- When `on_change` raises, the update is rejected without a reply. The server
  doesn't acknowledge or broadcast it, and there is no negative ack. The
  client keeps the update and resends it on a timer and on reconnect. That
  works for transient failures, such as a store that was down for a moment.
  A block that raises every time for the same edit gets retried forever,
  because nothing tells the client to stop. Enforce hard rejections in the
  channel's authorization at subscribe time, before an edit reaches
  `on_change`.
- An oversized frame is dropped the same way. The server drops any frame
  larger than `max_frame_bytes` (8 MiB by default) before decoding it, with
  no ack and no broadcast. This limits the work one client can force on the
  server. A real document update over the cap gets the same treatment as a
  raising `on_change`. Normal typing never comes near the cap, but a large
  paste, an embedded image, or a big initial `SyncStep2` can exceed it. The
  server logs each drop with the document key and update id. Override
  `sync_log_context` on the channel to add a user or connection id to that
  log line.

## Frame validation

The server checks that each incoming frame is a single well-formed protocol
message before it processes or relays it. It drops malformed, truncated,
multi-message, oversized, and unknown frames. A Rust panic in the native code
is caught and raised as a Ruby exception, so a bad frame can't crash the
process. One client can't relay garbage that breaks the other clients in a
room.

Validation checks each frame's shape, and it doesn't limit how many frames a
client sends. A client that sends valid frames as fast as it can needs a rate
limit. This site's channels put token buckets in front of `sync_receive` for
that reason. The site's
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md) describes
them.

## Reliable delivery (acks)

The server acknowledges document updates. Each browser update includes an
`"id"`, and the server replies `{ "ack": <id> }` after `on_change` returns.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # saved; the client can drop update 42
```

`yrby-client`'s `ActionCableProvider` handles this for you. It queues local
updates until they're acknowledged and sends the queue merged into one
causally complete delta. The id is the highest sequence number in the batch,
so one ack confirms everything up to it. If the server already has a resent
update, applying it again has no effect and the server acknowledges it again.
Awareness is ephemeral, and the server doesn't acknowledge it.

## Causal gaps

Yjs updates can arrive out of order, so an update can reach the server before
the update it depends on. yrby treats that as normal. The server saves and
acknowledges the update like any other. The update waits in the document as a
pending struct, and Yjs integrates it when the missing dependency arrives. The
write path appends, relays, and acknowledges without rebuilding the document,
so an update with a gap costs the same as any other.

The server also sends pending structs to other clients. `handle_sync_message`
answers with the full state, pending structs included. A client that receives
it holds the same pending struct and integrates it the same way. Closing the
gap needs no special handling. The missing update is still unacknowledged on
the client that sent it, and that client keeps resending it. Only compaction
leaves pending structs out, because folding them into the base snapshot would
make them impossible to integrate.

An open gap is easy to miss. The pending edit doesn't appear in the document
until its dependency arrives. The gap worth alerting on is one that no
connected client can fill. The `on_gap` hook reports it. Whenever the server
loads a document to send its state and a gap is open, it calls `on_gap` with
the document key.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_gap { |key| StatsD.increment("yrby.gap", tags: ["doc:#{key}"]) }
end
```

The server also logs open gaps at `info`. It catches and logs errors raised in
the hook, so a broken metrics call can't break frame handling.

## Sync flow

```
Browser                                    Server
   |                                          |
   |--- subscribe -------------------------->|  authorized?
   |<-- SyncStep1 (server's state vector) ---|  read through on_load
   |--- SyncStep2 (what the server lacks) -->|  saved through on_change
   |                                          |
   |--- SyncStep1 + awareness -------------->|
   |<-- SyncStep2 (full state) --------------|  the browser is synced
   |                                          |
   |--- update { id } ---------------------->|  saved, then broadcast
   |<-- { ack: id } -------------------------|
   |<-- updates from other clients ----------|
```

## Message type constants

```ruby
Y::MSG_SYNC            # 0 - document sync message
Y::MSG_AWARENESS       # 1 - presence update

Y::MSG_SYNC_STEP1      # 0 - state vector request
Y::MSG_SYNC_STEP2      # 1 - update response
Y::MSG_SYNC_UPDATE     # 2 - incremental update
```

## Protocol codec

Classifying and unwrapping a frame needs no state, so these are module
functions on `Y`. The server routes frames without holding presence or
document state.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta in a frame, or nil
Y.wrap_update(update_bytes)   # => a raw document update wrapped as a sync Update frame
```
