# Changelog: yrby-forms

All notable changes to the `yrby-forms` gem are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first release.

### Added

- `has_collaborative_fields :status, :summary` declares which attributes of a
  model collaborate. Enums are last-write-wins. String and text columns merge
  concurrent typing through a Y.Text. Every other type is last-write-wins.
  `text:` and `lww:` force a tier. A name that isn't an attribute raises when
  the class loads.
- The fields share one collaborative document per record, declared as
  `has_collaborative_document "fields"` with `Y::Forms::FieldsChannel` as its
  channel. Last-write-wins values are entries in a `fields` map, and each
  text field is a Y.Text named `fields/<name>`. `encrypted: true` stores the
  document through `Y::EncryptedDocument`. Destroying the record destroys
  its document.
- `Y::Forms::FieldsChannel` ships with the gem and subclasses
  `Y::DocumentChannel`. It saves each change and then writes the record's
  columns. It accepts a grant only for the `fields` document of a model with
  collaborative fields, and `authorize_document` adds a check of the current
  user. A failed column write is logged and the change is still acknowledged.
- `refresh_collaborative_fields` writes the document's values to the declared
  columns under the record lock, with `save!(validate: false)`. Values are
  cast by the attribute types. Map keys outside the declared set are ignored,
  so a client can't write another column.
- `form.collaborative_fields` renders `<yrby-document>` with the record's
  grant, and takes `collaborative_document_tag`'s options. The presence name
  and color come from `Y::Forms.identity` and render as `data-user-name` and
  `data-user-color`.
- `form.collaborative_field :status` wraps the usual input for the attribute,
  or one from a block, in `<collaborative-field name tier>`.
- The `yrby-forms` npm package has the `<collaborative-field>` element.

Requires yrby-rails 0.9.0 or later.
