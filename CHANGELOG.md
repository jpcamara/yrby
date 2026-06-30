# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
