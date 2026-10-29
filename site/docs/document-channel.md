# The document channel

## The built-in channel

Most apps never write a channel. yrby-rails includes `Y::DocumentChannel`,
much like turbo-rails includes `Turbo::StreamsChannel`. The browser subscribes
with the signed token that `collaborative_document_tag` rendered. The channel
looks up the record from that token and saves every change before confirming
it. It rejects a token that's missing, tampered with, expired, signed for a
different attribute, or points at a deleted record.
[Getting started](/docs/getting-started) shows the setup.

By default, any valid token lets the browser subscribe. To also check the
connected user's current permissions, register a block in `config.to_prepare`:

```ruby
# config/initializers/yrby.rb, inside Rails.application.config.to_prepare
Y::DocumentChannel.authorize_document do |record, name|
  current_user.present? && record.editable_by?(current_user, attribute: name)
end
```

The block runs inside the channel, so `current_user` works. `editable_by?`
stands for your own permission check. yrby doesn't define it. If the block
returns false or nil, the channel rejects the subscription before sending
anything.

The rest of this page covers writing your own channel with the same concern.
You'd do that for Yjs documents keyed by room with no record behind them, to use a
different store, or to handle authorization yourself.

## Writing your own channel

Your channel includes the `Y::ActionCable` concern from yrby-rails. The
concern implements the y-websocket protocol, which covers syncing the Yjs
document and presence, and it works on both Action Cable and AnyCable. Each Yjs
document has a key. Use whatever scheme fits your app, such as
one per record and attribute (`post/42/body`) or one per room.

```ruby
# app/channels/document_channel.rb
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  def subscribed = sync_subscribed(params[:id])

  def receive(data) = sync_receive(data, params[:id])

  private

  # Rejects everyone until you replace it with your app's check.
  # sync_subscribed rejects the subscription unless this returns true.
  def authorized?(_document_key) = false
end
```

Storage defaults to the gem's `Y::Document` models. Declare the two hooks to
point it somewhere else:

```ruby
  on_load   { |key| Y::Document.load_state(key) }                # load the saved state
  on_change { |key, update| Y::Document.append(key, update) }    # save the change, then broadcast
```

`bin/rails generate yrby:install --channel` generates this channel for you,
with both hooks written out. Without `--channel`, the generator adds only the
storage migration.

## The two hooks

When the yrby-rails models are installed and a channel declares neither hook,
both hooks use `Y::Document`. To use a different store, declare both. If you
declare only one, subscribing raises an error, so reads and writes can't end
up in different stores. A subclass can override one hook and inherit the other,
as long as the parent declares both. Outside a Rails app with yrby-rails there
are no defaults.

`on_load` receives a key and returns a binary Y.js update, or nil when nothing
is stored under that key yet. `on_change` receives a key and the CRDT delta,
and it saves that delta. Both run in the channel instance through `instance_exec`, so they can
call `params`, `current_user`, and any other channel method.

The concern loads the saved state through `on_load` whenever a client syncs,
and saves each change through `on_change` before broadcasting it. It keeps no
Yjs document in memory, so AnyCable RPC workers, Puma workers, and separate
dynos can all handle the same Yjs document, as long as they share the store and the
cable adapter.

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

For a channel anyone may join, write `def authorized?(_key) = true`, so anyone reading
the code can see it's public on purpose.

`authorized?` runs once, when the client subscribes. The subscription is
authorized until it ends. To cut off access during a session, stop the
subscription yourself. Short token lifetimes also help, because the server
checks the token again on every new subscription.

For a Yjs document that belongs to a record attribute, use `Y::Collaborative`,
which the engine adds to every Active Record model. The page renders a signed
GlobalID for one attribute, and the channel looks up the record from it. The
browser never gets to pick which record or attribute it edits.

```erb
<%# the view picks the record attribute and signs it %>
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

The same idea works without records. This site's demo rooms don't exist until
someone opens one, so there's no record to sign. Instead, the page signs the
room name with `Rails.application.message_verifier`, and `authorized?` only
accepts the key that token decodes to. This works well when subscribers are
anonymous.

## Save before broadcast

The concern calls `on_change` with every change before broadcasting it. Your
block should save it durably.

```ruby
on_change do |key, update|
  # Write synchronously and durably. `update` is the CRDT delta.
  AuditLog.append!(key, update)   # raising here rejects the change
end
```

If the block raises, the server rejects the change and doesn't send it to
anyone. The cost is one synchronous write per change. The gem doesn't lock
the stored updates, so concurrent writes can save the same update twice. That's
harmless, because applying a CRDT update twice has no effect.

## Delivery guarantees

These guarantees hold whether you run one process or hundreds across many
servers.

- Every copy of the Yjs document ends up the same. Updates can arrive out of
  order, twice, or at the same time, and the result doesn't change.
- Once the server confirms an update, it's saved, even if it arrived before an
  update it depends on. That early update waits in the Yjs document. The client
  that sent the missing one hasn't had it confirmed, so it keeps resending it
  until the server saves it.
- `on_change` runs at least once for every update, before the server confirms
  or broadcasts it. Replaying what it saved rebuilds the Yjs document. If you need
  exactly-once behavior, make `on_change` idempotent. The CRDT handles
  duplicates either way.
- If `on_change` raises, the server drops the update without replying. The
  client keeps it and resends it on a timer and on reconnect. That's what you
  want when the store was down for a moment. But if the block raises every
  time for the same edit, the client retries forever, because nothing tells it
  to stop. Put permanent rejections in `authorized?`, which runs when the client
  subscribes.
- Messages larger than `max_frame_bytes` (8 MiB by default) are dropped the
  same way, before the server parses them. This limits how much work one
  client can cause. Typing never gets close, but a big paste, an embedded image, or a
  large first sync can. A real edit over the limit gets retried forever, like
  one that makes `on_change` raise. The server logs each drop with the
  document key and update id. To add a user or connection id to that line,
  override `sync_log_context` on the channel.

## Frame validation

Before the server uses or forwards a message, it checks that it's one
complete, well-formed protocol message. It drops anything malformed,
truncated, oversized, of an unknown type, or holding more than one message. If
the Rust code panics, Ruby raises an exception and the process keeps running.
So one client can't send a message that breaks the room for everyone else.

Validation doesn't limit how many messages a client sends. A client sending
valid messages as fast as it can still needs a rate limit. This site's
channels put token buckets in front of `sync_receive` for that, and the site's
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md) describes
them.

## Reliable delivery (acks)

The server acknowledges each update to the Yjs document. Each browser update
includes an `"id"`, and the server replies `{ "ack": <id> }` after `on_change` returns.

```
client -> server   { "update": "<base64 update>", "id": 42 }
server -> client   { "ack": 42 }     # saved; the client can drop update 42
```

`yrby-client`'s `ActionCableProvider` does this for you. It queues local
updates until they're confirmed and sends them merged into one update. The id
is the highest sequence number in the batch, so one ack confirms all of them.
If the server gets an update it already has, applying it changes nothing, and
the server acks it again. Presence updates aren't acked.

## Causal gaps

An update can reach the server before the update it depends on. That's
normal, and the server saves and confirms it like any other. Yjs holds it in
the Yjs document as a pending struct and applies it once the missing update
arrives. It costs the same as any other update, because the server appends
it, forwards it, and acks it without rebuilding the Yjs document.

Other clients get pending structs too, because `handle_sync_message` answers
with the full state. They hold the same pending struct and apply it the same
way. Nothing special has to happen to close the gap. The client that sent the
missing update hasn't had it confirmed, so it keeps resending it. Compaction
is the exception. It leaves pending structs out of the snapshot, because a
pending struct folded into the snapshot could never be applied.

Gaps are easy to miss, because the pending edit doesn't show up in the
editor until its dependency arrives. A gap is worth an alert when no connected
client can fill it. Use the `on_gap` hook for that. Whenever the server
loads the saved state to send it to a client and finds a gap, it calls `on_gap`
with the document key.

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

These are module functions on `Y`, because classifying and unwrapping a
message doesn't need any state.

```ruby
Y.message_kind(frame)         # => 0 drop / 1 step1 / 2 update / 3 awareness / 4 query
Y.update_from_message(frame)  # => the document delta in a frame, or nil
Y.wrap_update(update_bytes)   # => a raw document update wrapped as a sync Update frame
```
