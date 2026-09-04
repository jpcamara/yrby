# yrby-forms

Collaborative form fields for Rails over [yrby](README.md). Declare which
attributes of a model collaborate, render them with two form helpers, and
every open form on that record shares live state: selects, checkboxes,
numbers, and dates converge last-write-wins per field; text fields merge
concurrent typing per character. The server materializes the shared values
back into the columns after every change.

Two packages, versioned together in this repo:

- **`yrby-forms` (gem)** — the model macro, the form helpers, the
  materializer, and an install generator for the channel.
- **[`yrby-forms` (npm)](packages/forms)** — the `<collaborative-form>` and
  `<collaborative-field>` custom elements the helpers render.

## Install

```ruby
# Gemfile
gem "yrby-forms"
```

```sh
bin/rails generate yrby_forms:install
bin/rails db:migrate
npm install yrby-forms yjs y-protocols
```

The generator creates `app/channels/form_fields_channel.rb` and the storage
migration (yrby's `y_documents` / `y_document_updates` tables). Import the
npm package once from your JavaScript entry point; importing registers the
elements.

## Declare and render

```ruby
class Ticket < ApplicationRecord
  enum :status, { triage: "triage", active: "active", done: "done" }

  has_collaborative_fields :status, :priority, :summary, :description
end
```

Declare enums before the macro; tier detection reads them. Tiers resolve per
attribute:

| Attribute | Tier |
|---|---|
| Rails enum | LWW |
| `:string` / `:text` column | text (Y.Text, character merge) |
| everything else (integer, boolean, date, datetime, decimal, …) | LWW |

Force a tier with the kwargs — they win over detection:

```ruby
has_collaborative_fields :summary, :notes, lww: [:summary]
```

A name that isn't a real attribute raises at declaration. `encrypted: true`
stores the CRDT state through `Y::EncryptedDocument` (the columns themselves
encrypt with your own `encrypts` declarations).

Render inside any form:

```erb
<%= form_with(model: @ticket) do |form| %>
  <%= form.collaborative_fields do %>
    <%= form.collaborative_field :status %>
    <%= form.collaborative_field :priority %>
    <%= form.collaborative_field :description %>
  <% end %>
<% end %>
```

`collaborative_field` renders the stock input for the attribute's type (enum
→ select, boolean → checkbox, date → date field, …). Pass a block to render
your own input instead:

```erb
<%= form.collaborative_field :status do %>
  <%= form.select :status, Ticket.statuses.keys %>
<% end %>
```

## How it works

One `Y::Document` per record (named `"fields"`) holds the whole field set:

- a `"fields"` map share keyed by field name for the LWW tier — each write
  replaces the value, last write wins per field;
- one `"fields/<name>"` Y.Text share per text-tier field — concurrent
  typing merges per character.

The generated FormFieldsChannel locates the record through the signed
GlobalID the helper minted, appends every update to the document, and then
calls `refresh_collaborative_fields`: under the record lock, the document is
reloaded, read (`read_map` / `read_text`), and the declared fields are
assigned and saved with `save!(validate: false)`. LWW values cast through
the attribute types, so `"7"` lands in an integer column as `7` and
`"2026-09-01"` in a date column as a date.

Only declared fields are ever assigned. The map is client-written — a
hostile client can put any key in it, another column's name included — and
every undeclared key is dropped before `assign_attributes`. A value an
attribute rejects (an unknown enum name) fails that materialization; the
channel logs it and the columns catch up on the next valid change.

## Authorization and identity

Access is enforced server-side, twice: the form helper mints a signed
GlobalID scoped to `Y::Forms.sgid_purpose`, so a token minted elsewhere
can't join a field set, and the generated channel's `authorized?` denies
everyone until you implement it:

```ruby
# app/channels/form_fields_channel.rb
def authorized?
  record.editable_by?(current_user)
end
```

Presence names and colors come from `Y::Forms.identity`, called with the
view context (the default reads `current_user`'s `name` / `username` /
`handle`, falling back to `"Anonymous"`):

```ruby
Y::Forms.identity = ->(view) { { name: view.current_user.handle, color: nil } }
```

Names are cosmetic; access is enforced. Presence metadata is written by the
client, so a tampered client can label itself with any name. What a client
can never do is grant itself access: reading and writing the field set are
gated by the signed GlobalID and your `authorized?` check, entirely on the
server. Treat the name on a field outline as a label for people who already
share the record, never as authentication.

## Limitations

- **No server→document write-back.** Column values flow from the shared
  document to the database, not the other way: an attribute assigned in
  Ruby is not written into an existing shared document, and a record's
  current column values do not seed a brand-new one (writing into a live
  document from the server needs yrby's document-editing API,
  [yrby#33](https://github.com/jpcamara/yrby/issues/33)). Until then the
  document is client-authored; treat the columns as the materialized view
  of it.
- v1 scope: no in-field remote carets (presence is per field), no offline
  queueing, no conflict UI, no nested attributes / `fields_for`. Rich text
  belongs to [lexxy-realtime](https://github.com/jpcamara/lexxy-realtime).

## The elements

See the [npm package README](packages/forms/README.md) for the element
attributes, the AnyCable consumer hook (`setConsumer`), and styling.

## Demo

The [actioncable-demo](examples/actioncable-demo)'s `/tickets/:id` page runs
the whole stack — helpers, channel, elements, materialization — and
`frontend/form_fields_e2e.mjs` drives it with two real browsers in CI.
