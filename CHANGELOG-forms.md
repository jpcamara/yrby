# Changelog: yrby-forms

All notable changes to the `yrby-forms` gem are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial gem: collaborative form fields over yrby, a thin adapter on
  yrby-rails' collaborative-document base (`has_collaborative_document`).
  - `has_collaborative_fields :status, :summary, ...` declares which
    attributes collaborate. Tiers are detected per attribute: Rails enums
    are LWW, string and text columns are text tier (Y.Text), everything
    else is LWW; `text:`/`lww:` kwargs force a tier. An unknown attribute
    raises at declaration. `encrypted: true` stores CRDT state through
    `Y::EncryptedDocument`. Under the hood the macro declares
    `has_collaborative_document :fields` with a tier-aware materialize
    block; the association, sgid flow, and refresh shell are the base's.
  - One `Y::Document` (named `"fields"`) per record holds the whole field
    set: LWW entries in a `"fields"` map share, one `"fields/<name>"`
    Y.Text share per text-tier field.
  - `refresh_collaborative_fields` materializes the document back into the
    declared columns under the record lock (`save!(validate: false)`),
    casting LWW values through the attribute types. Map keys outside the
    declared set are ignored: a client can write any key into the shared
    map, and none of them reach `assign_attributes`.
  - Form helpers: `form.collaborative_fields` renders the
    `<collaborative-form>` container through the base's
    `collaborative_document_tag` (doc id, channel, signed token, presence
    identity from `Y::Collaborative.identity`);
    `form.collaborative_field :status` wraps the stock input for the
    attribute — or a block-supplied one — in
    `<collaborative-field name tier>`.
  - `yrby_forms:install` generator: a FormFieldsChannel
    (`Y::Collaborative.locate` pinned to the field-set purpose,
    deny-by-default `authorized?`, storage through the record's document,
    refresh after every append) plus the storage migration via
    `yrby:tables`.
  - The companion npm package `yrby-forms` ships the two custom elements
    the helpers render.
