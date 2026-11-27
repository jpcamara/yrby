# yrby-forms

Collaborative form fields for Rails over [yrby](README.md). You declare which
attributes of a model collaborate and render them with two form helpers.
Every open form for that record then edits one shared document. Selects,
checkboxes, numbers, and dates are last-write-wins per field. Text fields
merge concurrent typing per character. The server writes the values to the
record's columns after every change.

It is two packages, versioned in this repo:

- **`yrby-forms` (gem)** has the model macro, the form helpers, and the
  channel.
- **[`yrby-forms` (npm)](packages/forms)** has the `<collaborative-field>`
  element. The connection is yrby-client's `<yrby-document>`.

A model can also keep the document in one of its own columns. Then the form
posts the document like any other field and needs no connection. See
[A document in a column](#a-document-in-a-column).

## Install

```ruby
# Gemfile
gem "yrby-forms"
```

```sh
bin/rails generate yrby:install
bin/rails db:migrate
npm install yrby-forms yjs y-protocols @rails/actioncable
```

`yrby:install` is yrby-rails' generator. It creates the migration for the
`y_documents` and `y_document_updates` tables. Skip it if the app already
has them.

Import the npm package once from your JavaScript entry point. Importing
registers the elements:

```js
import "yrby-forms"
```

An import-map app needs no npm. The gem ships the same module as an asset.
Pin it next to the pins `yrby:install` added:

```ruby
# config/importmap.rb
pin "yrby-forms", to: "yrby-forms/yrby-forms.js"
```

## Declare and render

```ruby
class Ticket < ApplicationRecord
  enum :status, { triage: "triage", active: "active", done: "done" }

  has_collaborative_fields :status, :priority, :summary, :description
end
```

Declare enums before the macro, because it reads them to pick each
attribute's tier:

| Attribute | Tier |
|---|---|
| Rails enum | `lww` |
| `:string` or `:text` column | `text` (a Y.Text, merged per character) |
| anything else (integer, boolean, date, datetime, decimal) | `lww` |

`text:` and `lww:` force a tier:

```ruby
has_collaborative_fields :summary, :notes, lww: [:summary]
```

A name that isn't an attribute raises when the class loads. `encrypted: true`
stores the document through `Y::EncryptedDocument`. To encrypt the columns,
use the model's own `encrypts`.

Render the fields inside any form:

```erb
<%= form_with(model: @ticket) do |form| %>
  <%= form.collaborative_fields do %>
    <%= form.collaborative_field :status %>
    <%= form.collaborative_field :priority %>
    <%= form.collaborative_field :description %>
  <% end %>
<% end %>
```

`collaborative_field` renders the usual input for the attribute's type: a
select for an enum, a checkbox for a boolean, a date field for a date. Pass a
block to render your own:

```erb
<%= form.collaborative_field :status do %>
  <%= form.select :status, Ticket.statuses.keys %>
<% end %>
```

`collaborative_fields` renders yrby's `<yrby-document>` with
`collaborative_document_tag`, and takes the same options, such as
`expires_in:` and `refresh:`.

## How it works

The macro declares one collaborative document on the model, as
`has_collaborative_document "fields", channel: "Y::Forms::FieldsChannel"`
would. The document holds the whole field set:

- A `fields` map has one entry per `lww` field. Each write replaces the
  value, and the last write wins.
- Each `text` field has its own Y.Text named `fields/<name>`.

`Y::Forms::FieldsChannel` ships with the gem and subclasses
`Y::DocumentChannel`. It saves each change and then calls
`refresh_collaborative_fields` on the record. That method locks the record,
reads the document, assigns the declared fields, and saves with
`save!(validate: false)`. Values are cast by the attribute types, so `"7"`
becomes `7` in an integer column and `"2026-09-01"` becomes a date.

Only declared fields are assigned. Clients write the map, so a client can put
any key in it, including another column's name. Keys outside the declared set
are dropped before `assign_attributes`.

A change is acknowledged once it is saved. If the column write then fails,
for example on an enum value the model rejects, the channel logs the error.
The columns catch up on the next change that can be written.

Destroying the record destroys its document.

## Authorization and identity

The form helper renders a grant signed for this record's `fields` document.
The channel accepts only that. A grant for another attribute, or for a model
without collaborative fields, is rejected.

A valid grant is enough by default, so the view that renders the form must
require edit permission. To also check the current user when a client
subscribes, give the channel an `authorize_document` block, as you would for
`Y::DocumentChannel`:

```ruby
# config/initializers/yrby_forms.rb
Rails.application.config.to_prepare do
  Y::Forms::FieldsChannel.authorize_document do |record, _name|
    current_user.present? && record.editable_by?(current_user)
  end
end
```

A block set on `Y::DocumentChannel` applies to forms too, until
`Y::Forms::FieldsChannel` has its own.

Presence names and colors come from `Y::Forms.identity`, which is called with
the view context. The default reads `current_user`'s `name`, `username`, or
`handle`, and uses `"Anonymous"` when there is none. A `nil` color becomes a
color derived from the name:

```ruby
Y::Forms.identity = ->(view) { { name: view.current_user.handle, color: nil } }
```

The helper renders the name and color as `data-user-name` and
`data-user-color` on `<yrby-document>`, and the browser sends them as
presence. A tampered client can show any name, so treat the name on a field
as a label. The grant and your `authorize_document` block decide who can read
and write.

## A document in a column

With `column:` the document is a column of the model's own table, stored as
Base64. There is no `y_documents` table, no channel, and no connection:

```ruby
class Draft < ApplicationRecord
  has_collaborative_fields :title, :body, column: :fields_ydoc
end
```

```ruby
add_column :drafts, :fields_ydoc, :text
```

The form is the same, and the controller is a plain one that permits the
column with the fields:

```erb
<%= form_with(model: @draft) do |form| %>
  <%= form.collaborative_fields do %>
    <%= form.collaborative_field :title %>
    <%= form.collaborative_field :body %>
  <% end %>
<% end %>
```

```ruby
def update
  @draft.update!(params.expect(draft: [:title, :body, :fields_ydoc]))
  redirect_to @draft
end
```

`collaborative_fields` renders `<collaborative-fields>` with the document in
its `value` attribute. The element adds the edited document to the form's
data under the column's name, so every submit carries it. A `before_save`
callback merges the posted document into the stored one and reads the
declared fields from the result. Two people who submit the same form both
keep their edits, and nobody gets a `StaleObjectError`.

Pass `autosave: true` to post the form 300 ms after an edit, without a page
load. Edits made during the wait go in the same post, so steady typing saves
every 300 ms. The page that answers holds the merged document, and the
element merges it into the open form:

```erb
<%= form.collaborative_fields autosave: true do %>
```

A new document also reaches an open form when the `value` attribute changes,
which is what a Turbo morph of the page does. A bound control is left out of
the morph, so the person typing keeps their cursor.

This mode needs only `<collaborative-fields>` and `<collaborative-field>`.
An app with no connection can import them without yrby-client:

```js
import "yrby-forms/column"
```

```ruby
# config/importmap.rb
pin "yjs", to: "yrby/yjs.js"
pin "yrby-forms/column", to: "yrby-forms/column.js"
```

What to know about the column:

- The document owns the declared fields. On every save they are read from
  it, so a value assigned to a declared field in Ruby is replaced.
- A record gets its document on the first save, built from its text
  columns. For records that exist already, run `Draft.find_each(&:save!)`.
- A column that is not a valid document fails the save with an `:invalid`
  error on the column.
- The stored document is read under a row lock, so two saves at the same
  moment merge one after the other.
- There is no presence, because there is no connection.
- `encrypted:` is rejected. Use the model's own `encrypts :fields_ydoc`.

Anything that saves the record through Active Record merges the same way, so
a sync layer that writes the column works as the transport. Offline edits
then merge when they arrive.

## Limitations

- Values go from the document to the columns, and not the other way. An
  attribute assigned in Ruby is not written to the document. With a
  `Y::Document`, a record's existing column values do not fill a new
  document. With `column:`, the text columns do.
- A change made to the document from Ruby does not reach the columns until
  you call `refresh_collaborative_fields` or a browser makes the next change.
- Presence is per field. There are no carets inside a field.
- Nothing is stored in the browser, so a change that has not reached the
  server is lost on reload.
- Nested attributes and `fields_for` are not supported.
- Rich text belongs to
  [lexxy-realtime](https://github.com/jpcamara/lexxy-realtime).

## The element

The [npm package README](packages/forms/README.md) covers the markup, the
presence state, using another consumer such as AnyCable's, and styling.

## Demo

The [actioncable-demo](examples/actioncable-demo)'s `/tickets/:id` page runs
all of it. `frontend/form_fields_e2e.mjs` drives the page with two browsers
in CI.
