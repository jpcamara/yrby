# Storage

A channel needs only two hooks, `on_load` and `on_change`, and they can use any
store. yrby ships an Active Record store because most apps want one, but the
protocol doesn't need a database.

## The bundled models

The models ship in the gem, as `ActionText::RichText` ships in Action Text.

`Y::Document` stores one row per document, and you can find a row in two ways.
Channels use `key`, a single unique string. The app can supply its own key,
and yrby never parses it. A row can also have a polymorphic `record` and a
`name`, which say which model attribute the document belongs to. `name` is the
attribute name, such as `"body"`. Documents created by key alone leave
`record` and `name` nil.

Either one can come first. `Y::Document.for(record, name)` finds or creates
the row for a record's attribute and gives it a readable key such as
`post/1/body`. If a channel already created a row under that key, `for` links
that row to the record. A channel that writes first and a record binding
created later end up on the same document.

The row also holds the merged `state` snapshot, which contains only CRDT
state. Your app handles derived data such as rendered HTML or search text,
usually in the channel's `on_change`. By default the channel concern calls
`.load_state(key)` to read the store and `.append(key, update)` to write it.

`Y::DocumentUpdate` holds the changes not yet compacted, one delta per row.
When there are `compact_every` of them (64 by default), yrby merges them into
`state` and deletes the rows. A load reads the snapshot plus any remaining
update rows. When there are none, it returns `state` as is. Compactions of one
document run one at a time under a row lock. Rows that belong to an open
causal gap aren't compacted or deleted. yrby marks them pending and keeps them
until the gap closes. Destroying a document deletes its update rows too.

The migration creates `y_documents` and `y_document_updates`. To rename them,
edit the generated migration and set `Y::Document.table_name` and
`Y::DocumentUpdate.table_name` to the new names in an initializer.

## Encrypted storage

`Y::EncryptedDocument` writes `state` and update payloads through Active Record
encryption, on the same tables, as `ActionText::EncryptedRichText` does.
You declare encryption on the model, so neither a page nor a client can turn
it off:

```ruby
class Post < ApplicationRecord
  has_collaborative_document :body, encrypted: true
end
```

`Y::DocumentChannel` reads that declaration and sends every load and append
for the attribute through the encrypted class. Attributes without it use plain
`Y::Document`. In a channel of your own, point `on_load` and `on_change` at
`Y::EncryptedDocument`. In both cases, configure your app's Active Record
encryption keys, and always read a document through the same class. The plain
classes return encrypted rows as ciphertext.

## Record-backed access

`post.collaborative_document(:body)` returns a `Y::Collaborative::Attribute`
for that record and attribute. It has `load_state`, `append(update)`, `key`,
and `y_doc`. `y_doc` builds a new native `Y::Doc` that you can read and render
in Ruby. For row operations such as compaction, call
`post.collaborative_document(:body).document_row.compact!`. The channel and
your app code both use this object, and it handles encryption for both.

An attribute's key is the key its row was saved under. Before a row exists,
the key is `Y::Document.key_for(record, name)`. Computing it doesn't create a
row.

For a store other than `Y::Document`, write your own channel with `on_load`
and `on_change` hooks, as shown below.

## Writing your own store

Your store needs to do two things.

### Load without losing pending updates, and accept duplicates

`on_load` should return state that keeps pending updates. Use
`encode_state_as_update`, or replay the raw append log. Don't compact with
`compacted_state_update` while `doc.pending?` is true. That drops the pending
struct, and with it an edit the server already acknowledged.

When an ack gets lost, the client resends an update the store already has.
Replaying the log still produces the same document, because applying a CRDT
update twice has no effect. Deduplicating is optional. If log size matters,
deduplicate by content hash:

```ruby
class DocumentStore
  # Appending a duplicate update is a no-op upsert.
  def append(key, update)
    Revision.upsert({ doc_key: key, update_hash: Digest::SHA256.hexdigest(update), update: update },
                    unique_by: %i[doc_key update_hash])
  end

  # Replay the raw log so a pending struct is kept and can integrate
  # when its dependency arrives.
  def load(key)
    updates = Revision.where(doc_key: key).order(:id).pluck(:update)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each { |u| doc.apply_update(u) }
    doc.encode_state_as_update # keeps pending structs
  end

  # Optional. Compact only when no gap is open.
  def compact(key)
    doc = Y::Doc.new
    Revision.where(doc_key: key).order(:id).pluck(:update).each { |u| doc.apply_update(u) }
    return if doc.pending? # a gap is open, and compacting now would drop it
    # ... replace the log with one revision holding doc.compacted_state_update ...
  end
end
```

### Watch for gaps that don't close

An open gap is easy to miss, because the pending edit doesn't appear in the
document until its dependency arrives. Usually the gap closes by itself. The
sender resends the missing update until the server acknowledges it. Every
handshake also asks the client for everything the server is missing. Use the
`on_gap` hook to emit a metric, so you can see a gap that doesn't close.

## Pending structs and gap-free state

When a doc applies an update whose dependency is missing, yrs holds it as a
pending struct. The integrated state vector doesn't move. yrs keeps the
pending struct and integrates it if the missing dependency arrives later.
`Doc#pending?` returns true while a doc is in this state.

Pending updates are stored and sent like any other state. Don't fold them into
a compacted snapshot.

- `Doc#compacted_state_update` returns a full-state update without pending
  structs, for compaction. A compacted snapshot that included them would keep
  them pending forever. The call doesn't change the doc, which keeps its
  pending structs.
- `encode_state_as_update` includes pending structs. Use it for persistence
  and for sending state, so a gap can still close.

## Ephemeral documents (no database)

Some documents only need to last for a session: a scratchpad, live form state,
a draft you save on submit. For those, the channel can keep the document in
connection state.

```ruby
class ScratchpadChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| @doc_state }

  on_change do |key, update|
    doc = Y::Doc.new
    doc.apply_update(@doc_state) if @doc_state
    doc.apply_update(update)
    @doc_state = doc.encode_state_as_update
  end

  def subscribed    = sync_subscribed(params[:id])
  def receive(data) = sync_receive(data, params[:id])

  private

  # Each connection has its own scratchpad.
  def authorized?(_key) = true
end
```

On Action Cable the channel instance lasts as long as the connection, so an
instance variable is all the store you need. AnyCable builds a new channel
instance for each message. There, declare the store as channel state with
`state_attr_accessor` from anycable-rails, and Base64-encode it. AnyCable
serializes that state as JSON in every RPC call to `anycable-go`, so keep
these documents small.

Each connection has its own store, which limits what this pattern is good
for. A single writer gets the full delivery contract with no database. When
several people edit at once, one client's update can depend on edits its own
connection has never seen. The server saves that update as pending. The next
handshake with that client supplies the missing state and closes the gap. The
document still converges, but heavy concurrent editing leaves more pending
updates between handshakes than a shared store would.

The connection and the browsers hold the only copies. After a server restart,
a reconnecting client sends its state back through the normal sync handshake.
The document survives as long as some client still has it.

## The store this site runs on

This site's shape demos (spreadsheet, whiteboard, kanban, code, and Tiptap)
use the same store this page describes, on SQLite:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load   { |key|         Y::Document.load_state(key) }
  on_change { |key, update| Y::Document.append(key, update) }
end
```

The models don't depend on SQLite. Around the hooks, the site adds caps on
peers per room, documents on disk, and bytes per document. A sweeper deletes
rooms that nobody has edited for a day, because public, anonymous documents
should be temporary.

The site runs under AnyCable, so it also shows the constraint described in
[AnyCable and multi-process](/docs/anycable). Each command gets a new channel
instance, and anything that has to last between commands goes in
`state_attr_accessor`.

The full site, including every rate and size limit, is in
[`site/`](https://github.com/jpcamara/yrby/tree/main/site). Its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md) explains
the setup.
