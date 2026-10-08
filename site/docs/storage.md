# Storage

A channel only needs two hooks, `on_load` and `on_change`, and they can talk to
any store. yrby comes with an Active Record store because most apps want one.
You can also store Yjs documents somewhere else, or nowhere at all.

## The bundled models

The models come with the gem, the same way `ActionText::RichText` comes with
Action Text.

`Y::Document` stores one row per Yjs document. Each row has a unique `key`, which
is what channels use. Your app can pick the key, and yrby never parses it. A
row can also point at a model attribute through a polymorphic `record` and a
`name`, such as `"body"`. Rows created by key alone leave those two nil.

You can create a row by key or by record, in either order.
`Y::Document.for(record, name)` finds or creates the row for a record's
attribute, with a readable key like `post/1/body`. If a channel already
created a row with that key, `for` links it to the record, so both end up on
the same row.

The row also holds `state`, the merged snapshot of the Yjs document, and
nothing else. If you want rendered HTML or search text, compute it yourself, usually
in the channel's `on_change`. By default the channel reads with
`.load_state(key)` and writes with `.append(key, update)`.

`Y::DocumentUpdate` holds the changes that haven't been compacted yet, one per
row. Once there are `compact_every` of them (64 by default), yrby merges them
into `state` and deletes the rows. Loading the saved state reads the snapshot
plus any remaining update rows. A row lock keeps two compactions of the same
`Y::Document` row from running at once. Rows that belong to an open gap are
marked pending and kept until the gap closes. Destroying a `Y::Document` row
deletes its update rows too.

The migration creates `y_documents` and `y_document_updates`. To rename them,
edit the generated migration and set `Y::Document.table_name` and
`Y::DocumentUpdate.table_name` to the new names in an initializer.

## Encrypted storage

`Y::EncryptedDocument` uses the same tables and encrypts `state` and the
updates with Active Record encryption. You turn it on in the model, so no page
or client can switch it off:

```ruby
class Post < ApplicationRecord
  has_collaborative_document :body, encrypted: true
end
```

`Y::DocumentChannel` sees that and loads and saves the attribute through the
encrypted class. Other attributes use plain `Y::Document`. In your own channel,
point `on_load` and `on_change` at `Y::EncryptedDocument`. Either way, you need
Active Record encryption keys set up, and you should always read an attribute's
rows through the same class. Reading an encrypted row through the plain class gives
you ciphertext.

## Record-backed access

`post.collaborative_document(:body)` returns a `Y::Collaborative::Attribute`
with `load_state`, `append(update)`, `key`, and `y_doc`. `y_doc` builds a fresh
`Y::Doc` you can read and render in Ruby. For row-level work like compaction,
call `post.collaborative_document(:body).document_row.compact!`. The channel
uses this same object, so encryption works the same way in both places.

An attribute's key is the key its row was saved under. Before a row exists,
the key is `Y::Document.key_for(record, name)`. Computing it doesn't create a
row.

For a store other than `Y::Document`, write your own channel with `on_load`
and `on_change` hooks, as shown below.

## Writing your own store

Your store needs to do two things.

### Load without losing pending updates, and accept duplicates

`on_load` has to return state that still includes pending updates. Use
`encode_state_as_update`, or replay the raw log. Don't compact with
`compacted_state_update` while `doc.pending?` is true. That drops the pending
struct, and with it an edit the server already confirmed.

When an ack gets lost, the client resends an update the store already has.
Replaying the log still produces the same Yjs document, because applying a CRDT
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
editor until its dependency arrives. Usually the gap closes by itself. The
sender resends the missing update until the server acknowledges it. Every
handshake also asks the client for everything the server is missing. Use the
`on_gap` hook to emit a metric, so you can see a gap that doesn't close.

## Pending structs and gap-free state

When a `Y::Doc` gets an update whose dependency is missing, yrs holds it as a
pending struct and applies it if the dependency arrives later. Until then, the
doc's state vector doesn't include it, and `Doc#pending?` returns true.

Pending updates are stored and sent like any other state. Don't fold them into
a compacted snapshot.

- `Doc#compacted_state_update` returns the full state without pending
  structs. Use it for compaction, since a snapshot that included them would
  leave them pending forever. It doesn't change the doc.
- `encode_state_as_update` includes pending structs. Use it for persistence
  and for sending state, so a gap can still close.

## Ephemeral documents (no database)

Some content only needs to last for one session, like a scratchpad, live form
state, or a draft you save on submit. For those, the channel can keep the Yjs
state on the connection.

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
this state small.

Each connection has its own copy, which limits where this fits. With one
person editing, you get every delivery guarantee and no database. With
several people, one client's update can depend on edits its connection hasn't
seen. The server saves it as pending, and the next handshake with that client
fills the gap. Everyone still ends up with the same Yjs document, but with heavy
editing, more updates sit pending between handshakes than they would with a
shared store.

The connection and the browsers hold the only copies. After a server restart,
a reconnecting client sends its state back through the normal sync handshake.
The content survives as long as some client still has a copy.

## The store this site uses

This site's shape demos (spreadsheet, whiteboard, kanban, code, and Tiptap)
use the same store this page describes, on SQLite:

```ruby
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load   { |key|         Y::Document.load_state(key) }
  on_change { |key, update| Y::Document.append(key, update) }
end
```

SQLite isn't required. It's just what this site uses. On top of the hooks, the
site caps people per room, rooms saved on disk, and bytes stored per room. A
sweeper deletes rooms nobody has edited for a day, since public, anonymous
content shouldn't stick around.

The site runs on AnyCable, where each command gets a new channel instance. So
anything that has to last between commands goes in `state_attr_accessor`, as
[AnyCable and multi-process](/docs/anycable) describes.

The full site, including every rate and size limit, is in
[`site/`](https://github.com/jpcamara/yrby/tree/main/site). Its
[README](https://github.com/jpcamara/yrby/blob/main/site/README.md) explains
the setup.
