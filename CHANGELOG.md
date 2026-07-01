# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.3] - 2026-07-01

### Fixed

- `Doc#update_advances?` is now exact for **delete-bearing** updates, so an
  already-applied pure-delete retry no longer reports as advancing. Previously any
  update carrying a delete set returned `true` (record it) because deletes don't
  move the state vector, so the cheap state-vector probe couldn't prove a
  duplicate. A lost-ack retry of a deletion the server had already integrated was
  therefore re-recorded and re-broadcast every time. For delete-bearing updates we
  now compare the full encoded document state (which includes the delete set)
  before vs. after a trial apply on an isolated probe: a genuinely new deletion
  changes it (`true`); an already-applied retry re-encodes identically (`false`).
  Insert/format-only updates keep the cheaper state-vector path, so only
  delete-bearing frames — a minority — pay for the exact comparison. The exactly-
  once guarantee is unchanged in the safe direction: a real deletion is never
  dropped.

  This lets `yrby-actioncable` (and any caller gating `on_change` on
  `update_advances?`) settle a duplicate pure-delete frame as `:applied` — acked,
  but not stored or relayed — so apps no longer need an app-level
  encode-and-compare guard around their durable writes.

## [0.2.2] - 2026-06-30

### Fixed

- `Doc#read_xml` now recovers text from **nested** Lexical/Lexxy blocks. Lexical
  embeds child blocks (list items, table cells, nested lists) as `Y.XmlText`
  embeds that `get_string` silently drops, so lists and tables previously came
  back empty. `read_xml` now walks the embeds: text runs build a line, inline
  children (links) join it, and nested block children flush and recurse — so a
  document with headings, formatted text, links, bullet/numbered/check/nested
  lists, blockquotes, code blocks and tables extracts every piece of text.
  Lexical decorator elements (horizontal rule, image) are skipped instead of
  emitting their `<UNDEFINED …>` serialization. ProseMirror handling is
  unchanged.

## [0.2.1] - 2026-06-29

### Changed
- **Internal:** renamed the native extension crate `y_ruby` → `yrby` (now loads
  from `lib/y/yrby.bundle`). No public API change — `require "y"` and `Y::Doc`
  are unchanged.

## [0.2.0] - 2026-06-28

First release. The public Ruby interface is the top-level module **`Y`**
(`Y::Doc`, `Y::Error`, `Y::VERSION`), loaded with `require "y"` — mirroring the
`y-rb` gem's `Y::Doc` interface.

### Added
- Native `Doc#read_text` and `Doc#read_map` readers — reconstruct plain text and
  a JSON map from the stored CRDT state in-process, server-side, with no Node or
  subprocess.

### Notes
- y-crdt wrapper over Rust `yrs` 0.27.2 (magnus/rb-sys), with the full
  y-websocket sync protocol + Awareness, thread-safe (`Send`/`Sync`,
  GVL released around CRDT work). Precompiled platform gems are published
  alongside the source gem so `gem install yrby` needs no Rust toolchain.
