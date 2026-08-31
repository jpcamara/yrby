# Storage

The channel only needs `on_load` and `on_change` answered, and they can point at
anything. yrby ships an Active Record store because most apps want one, but
nothing in the protocol requires a database.

## The bundled models

The models ship in the gem, the way Action Text owns `ActionText::RichText`.

**`Y::Document`** is one row per document, addressed two ways: by `key` (what a
channel addresses; one opaque, unique string, sometimes app-supplied, never
parsed) and, optionally, by polymorphic `record` + `name` (which model attribute
it backs; `name` is the attribute name, `"body"`). Key-only documents leave the
binding nil. Either side can arrive first: `Y::Document.for(record, name)` finds
or creates the binding, derives a readable key (`post/1/body`), and adopts a
key-only row already holding that key, so a channel writing first and a binding
created later converge on one document.

The row also holds the merged `state` snapshot — CRDT state only. Derived data
(rendered HTML, search text) is the application's job, typically in the
channel's `on_change`. `.load_state(key)` and `.append(key, update)` are the
store calls the generated channel uses.

**`Y::DocumentUpdate`** is the uncompacted tail, one delta per row, compacted
into `state` and deleted once the tail reaches `compact_every` (default 64).
Loading reads the snapshot plus the current tail; an empty tail returns `state`
directly. Compaction serializes on a per-document row lock and skips
causally-gapped rows: they are quarantined until they heal rather than compacted
into state or deleted. Destroying a document deletes its updates with it.

The migration creates `y_documents` and `y_document_updates`. To rename them,
edit the generated migration and point `Y::Document.table_name` /
`Y::DocumentUpdate.table_name` at the new names in an initializer.

## Encrypted storage

`Y::EncryptedDocument` stores `state` and update payloads through Active Record
encryption on the same tables, the way `ActionText::EncryptedRichText` does.
Point the channel's `on_load`/`on_change` at it instead and configure your app's
encryption keys. Use one access path per document: rows written encrypted read
back as ciphertext through the plain classes.

## Writing your own store

Two things matter.

**1. Load losslessly, and tolerate duplicates.** `on_load` should return state
that preserves pending: `encode_state_as_update`, or a replay of the raw append
log. Don't compact with `compacted_state_update` while `doc.pending?`; that
strips the pending struct and the acked edit inside it. A lost ack also means a
client resends an update the store already has. Replay converges anyway, because
CRDT apply is idempotent, so deduping is optional. If log size matters, dedup by
content hash.

```ruby
class DocumentStore
  # append tolerates duplicates: a re-delivered update upserts to a no-op.
  def append(key, update)
    Revision.upsert({ doc_key: key, update_hash: Digest::SHA256.hexdigest(update), update: update },
                    unique_by: %i[doc_key update_hash])
  end

  # load is lossless: replay the raw log so a pending struct is preserved and
  # heals when its dependency arrives.
  def load(key)
    updates = Revision.where(doc_key: key).order(:id).pluck(:update)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each { |u| doc.apply_update(u) }
    doc.encode_state_as_update # lossless: keeps pending
  end

  # optional compaction: only when there is no open gap, or you would drop it.
  def compact(key)
    doc = Y::Doc.new
    Revision.where(doc_key: key).order(:id).pluck(:update).each { |u| doc.apply_update(u) }
    return if doc.pending? # a gap is open; compacting now would drop it
    # ... replace the log with a single revision holding doc.compacted_state_update ...
  end
end
```

**2. Watch for gaps that never heal.** An open gap is quiet: the edit sits as
pending, invisible in the document, until its dependency arrives. Normally that
resolves itself, because the sender retransmits until it is acked and every join
handshake has the client send everything the server hasn't integrated. Use the
`on_gap` hook to emit a metric so a stuck gap is visible.

## Pending structs and gap-free state

If a doc applies an update whose causally-prior update is missing, yrs parks it
as a **pending** struct: the integrated state vector stays empty, but the
pending block is held as a recovery buffer and heals if the missing dependency
later arrives. `Doc#pending?` reports this.

Pending structs travel like any other state. The one place pending must not go
is a compacted snapshot.

- `Doc#compacted_state_update` returns a gap-free full-state update for
  compaction. Folding a log into one blob would otherwise freeze an
  un-integrable struct into the base state forever. It is non-destructive: the
  doc keeps its pending.
- `encode_state_as_update` stays lossless, so persistence and serving keep the
  raw pending bytes and the gap can still heal.

## Ephemeral documents (no database)

For documents that don't need to outlive their session — a scratchpad, live form
state, a draft you only persist on submit — the store can be connection state
that travels with each request.

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| @doc_state }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(@doc_state) if @doc_state
    doc.apply_update(update)
    @doc_state = doc.compacted_state_update
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])
end
```

On Action Cable the channel instance lasts as long as the connection, so an
instance variable is the whole store. On AnyCable the channel object doesn't
survive between messages, so declare the store as channel state instead
(`state_attr_accessor` from anycable-rails) and Base64 it, because that state is
serialized as JSON into each RPC exchange with `anycable-go`.

The store is per connection, which shapes what this fits. A single writer gets
the full delivery contract with no database anywhere. With several people
editing at once, one client's update can depend on edits its own connection has
never seen; that update records as pending, and the next handshake with that
client supplies the missing state and heals it. The document still converges;
heavy concurrent editing just parks more pending between handshakes than a
shared store would.

Durability is the connection plus the browsers. A reconnecting client re-seeds
an empty server through the ordinary sync handshake, so the document survives
server restarts as long as some client still has it.

## The store this site runs on

For documents shared across clients on a single-process deployment, the same two
hooks over a process-wide Hash work instead. That is what this site does. It has
no database, no Redis, and an `async` cable adapter, and every demo room is a
document in one process's memory.

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load   { |key|         RoomStore.current.load(key) }
  on_change { |key, update| RoomStore.current.append(key, update) }
end
```

The store keeps a compacted snapshot plus a tail of raw updates per room. `load`
replays the snapshot and the tail into a fresh `Y::Doc` and returns
`encode_state_as_update`, so pending survives. Every 32 appends it folds the
tail into `compacted_state_update` — and skips while `doc.pending?`, because a
snapshot must not carry a gap.

That version stops being coherent the moment you scale past one process: a
second process would serve different documents under the same key, and `async`
broadcasts don't cross processes anyway. It is the right shape for ephemeral
demo rooms and the wrong shape for anything you would miss. Rooms here are
dropped after 20 minutes idle and lost on restart.

The whole thing, including every rate and size limit, is in
[`site/`](https://github.com/jpcamara/yrby/tree/main/site) and written up in its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md).
