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

## Limitations

- Values go from the document to the columns, and not the other way. An
  attribute assigned in Ruby is not written to the document, and a record's
  existing column values do not fill a new document.
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
