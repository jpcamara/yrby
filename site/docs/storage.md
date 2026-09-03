# Storage

The channel only needs `on_load` and `on_change` answered, and they can point at
anything. yrby ships an Active Record store because most apps want one, but the
protocol itself doesn't need a database.

## The bundled models

The models ship in the gem, the same way Action Text owns
`ActionText::RichText`.

**`Y::Document`** is one row per document. A row is addressed two ways. The
first is by `key`, which is what a channel uses: one opaque, unique string,
sometimes supplied by the app, never parsed. The second is optional: a
polymorphic `record` plus a `name`, which say which model attribute the
document backs (`name` is the attribute name, like `"body"`). Key-only
documents leave that binding nil. Either side can arrive first.
`Y::Document.for(record, name)` finds or creates the binding, derives a readable
key (`post/1/body`), and adopts a key-only row that already holds that key. So
a channel that writes first and a binding created later end up on the same
document.

The row also holds the merged `state` snapshot, and that is CRDT state only.
Derived data like rendered HTML or search text is the application's job,
usually done in the channel's `on_change`. `.load_state(key)` and
`.append(key, update)` are the store calls the channel concern uses by default.

**`Y::DocumentUpdate`** is the uncompacted tail, one delta per row. Once the
tail reaches `compact_every` (default 64) it is compacted into `state` and
deleted. Loading reads the snapshot plus the current tail, and an empty tail
returns `state` directly. Compaction serializes on a per-document row lock and
skips rows with an open causal gap. Those are held back until they heal instead
of being compacted into state or deleted. Destroying a document deletes its
updates with it.

The migration creates `y_documents` and `y_document_updates`. To rename them,
edit the generated migration and point `Y::Document.table_name` and
`Y::DocumentUpdate.table_name` at the new names in an initializer.

## Encrypted storage

`Y::EncryptedDocument` stores `state` and update payloads through Active Record
encryption, on the same tables, the way `ActionText::EncryptedRichText` does.
Declare it on the model. Encryption is a property of how the attribute is
stored, and a page or client never gets to choose it:

```ruby
class Post < ApplicationRecord
  has_collaborative_document :body, encrypted: true
end
```

`Y::DocumentChannel` reads that declaration and routes every load and append
for the attribute through the encrypted class. Attributes without the
declaration keep using plain `Y::Document`. In a channel of your own, point
`on_load` and `on_change` at `Y::EncryptedDocument` instead. Either way,
configure your app's encryption keys and use one access path per document.
Rows written encrypted read back as ciphertext through the plain classes.

## Writing your own store

Two things matter.

**1. Load losslessly, and tolerate duplicates.** `on_load` should return state
that preserves pending updates: `encode_state_as_update`, or a replay of the
raw append log. Don't compact with `compacted_state_update` while
`doc.pending?` is true. That strips the pending struct, and the acked edit
inside it goes with it. A lost ack also means a client resends an update the
store already has. Replay converges anyway, because CRDT apply is idempotent,
so deduping is optional. If log size matters, dedup by content hash.

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

**2. Watch for gaps that never heal.** An open gap doesn't announce itself. The
edit sits as pending, invisible in the document, until its dependency arrives.
Normally that resolves on its own: the sender retransmits until it is acked,
and every join handshake has the client send everything the server hasn't
integrated. Use the `on_gap` hook to emit a metric so a stuck gap is visible.

## Pending structs and gap-free state

If a doc applies an update whose causally-prior update is missing, yrs parks it
as a **pending** struct. The integrated state vector stays where it was, and
the pending block is held as a recovery buffer that heals if the missing
dependency arrives later. `Doc#pending?` reports this.

Pending structs travel like any other state. The one place pending must not go
is a compacted snapshot.

- `Doc#compacted_state_update` returns a gap-free full-state update for
  compaction. Folding a log into one blob would otherwise freeze an
  un-integrable struct into the base state for good. It is non-destructive: the
  doc keeps its pending.
- `encode_state_as_update` stays lossless, so persistence and serving keep the
  raw pending bytes and the gap can still heal.

## Ephemeral documents (no database)

Some documents don't need to outlive their session: a scratchpad, live form
state, a draft you only persist on submit. For those, the store can be
connection state that travels with each request.

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

  private

  # The scratchpad lives on this connection: every subscriber gets their own.
  def authorized?(_key) = true
end
```

On Action Cable the channel instance lasts as long as the connection, so an
instance variable is the whole store. On AnyCable the channel object doesn't
survive between messages, so declare the store as channel state instead
(`state_attr_accessor` from anycable-rails) and Base64 it, because that state
is serialized as JSON into each RPC exchange with `anycable-go`.

The store is per connection, and that shapes what this is good for. A single
writer gets the full delivery contract with no database anywhere. With several
people editing at once, one client's update can depend on edits its own
connection has never seen. That update records as pending, and the next
handshake with that client supplies the missing state and heals it. The
document still converges. Heavy concurrent editing just parks more pending
between handshakes than a shared store would.

Durability is the connection plus the browsers. A reconnecting client re-seeds
an empty server through the ordinary sync handshake, so the document survives a
server restart as long as some client still has it.

## The store this site runs on

This site's own demo rooms run the canonical stack from this page, on SQLite:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load   { |key|         Y::Document.load_state(key) }
  on_change { |key, update| Y::Document.append(key, update) }
end
```

Nothing about the models cares that the database is SQLite. The same channel
runs unchanged against Postgres in `examples/actioncable-demo`. What the site
adds around the hooks is caps (peers per room, documents on disk, bytes per
document) and a sweeper that deletes rooms untouched for a day, because public
anonymous documents should be temporary.

Because the channel runs under AnyCable, it is also a worked example of the
constraint in [AnyCable and multi-process](/docs/anycable): a fresh channel
instance per command, so anything that has to survive between commands goes in
`state_attr_accessor` instead of an instance variable.

The whole thing, including every rate and size limit, is in
[`site/`](https://github.com/jpcamara/yrby/tree/main/site) and written up in its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md).
