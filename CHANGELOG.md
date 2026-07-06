# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Y::ProseMirror` — render ProseMirror/Tiptap documents to HTML.**
  `Y::ProseMirror.new(doc).to_html` turns a Tiptap document into HTML on the
  server, with no Node process or headless editor. The output matches Tiptap's
  own `getHTML()`; the tests check it byte-for-byte against a document captured
  from a real editor. It follows `ueberdosis/tiptap-php` and reads both name
  styles editors use — Tiptap's `bulletList`/`bold` and prosemirror-schema-basic's
  `bullet_list`/`strong`. Covers paragraphs, headings, blockquotes,
  bullet/ordered/task lists, code blocks, links, images, mentions, details,
  hard breaks, horizontal rules, tables, text styles (color, font family), and
  every text mark. A table renders as semantic `<table><tbody>` without the
  editor's column-width styling. A root that isn't ProseMirror (a Lexical
  document, say) returns `nil`.

## [0.3.1] - 2026-07-01

Fixes from a full source review.

### Fixed

- **`Doc#update_ready?` is now exact.** It previously checked only the
  per-client clock lower bound, but yrs's real integration gate also requires
  every block referenced by an item's origin / right-origin / parent — which
  routinely belong to *other* clients — and post-Skip blocks in a merged update
  sit above the lower bound. An update could pass the clock check yet park as
  pending; downstream, `update_advances?` then misread the parked update as an
  already-applied retry (pending doesn't move a state vector) and the sync
  channel **acked and dropped real content**. `update_ready?` now
  trial-integrates on a throwaway probe seeded with the doc's integrated state
  (the clock check remains as a cheap pre-filter), so a cross-client-origin gap
  is correctly rejected for a resync. `update_advances?` also gained defense in
  depth: an update that would park reports as advancing, never as a duplicate.
- **`Doc#read_text` could deadlock the process.** It opened a second read
  transaction while still holding the first (a chained temporary); yrs's lock is
  write-preferring, so a concurrent writer between the two acquisitions
  deadlocked reader-vs-writer inside the GVL-released (uninterruptible) region.
  Now uses a single transaction.
- **TOCTOU in gap-free encoding.** The pending check and the encode ran in
  separate transactions, so a concurrent gappy `apply_update` between them could
  make `handle_sync_message`/`compacted_state_update` serve pending structs
  anyway. Both now happen under one transaction.
- `read_xml`: Lexical soft line breaks and tabs now come through as `\n`/`\t`
  instead of vanishing (`"foo⏎bar"` no longer extracts as `"foobar"`).

### Changed

- `update_advances?` skips its full-document probe when the update carries
  blocks beyond the doc's state vector (a novel update trivially advances) —
  the common case no longer pays O(doc) per frame.
- The gem no longer packages the `yrby-decoder` gem's files (they ship in that
  gem; the duplicate copy could shadow a newer standalone release), and now
  ships `Cargo.lock` so source builds compile the exact crate graph CI tested.

## [0.3.0] - 2026-07-01

### Fixed

- **Sync no longer serves un-integrable pending structs.** When a doc holds a
  *pending* struct (a gappy update whose causally-prior update is missing — e.g.
  legacy data recorded before the `update_ready?` gate existed), its integrated
  state vector is empty but `encode_state_as_update` merges the pending bytes back
  in. Answering a peer's `SyncStep1` with that state handed the peer content it
  couldn't integrate, so it parked the same pending forever and the empty-SV /
  non-empty-content mismatch drove endless resync traffic (observed as a browser
  re-sending frames several times a second). `handle_sync_message` now answers
  `SyncStep1` with **integrated-only** state, so a server never serves a struct it
  can't integrate itself. Neutralizes existing poisoned server state on deploy —
  no migration needed. The server's own pending is untouched and still heals if
  the missing dependency later arrives (only then does the content become
  visible in sync). Live delta relay (`Update` frames) is unchanged.

### Added

- `Doc#pending?` — true if the doc holds un-integrable pending structs or a
  pending delete set (content waiting on a missing causally-prior update).
- `Doc#compacted_state_update` — like `encode_state_as_update` (full state) but
  **gap-free**: excludes pending structs/delete set. Use it when persisting or
  serving state other peers will apply. Non-destructive — the doc keeps its
  pending (so it can still heal), and `encode_state_as_update` stays lossless for
  raw-update recovery.

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
