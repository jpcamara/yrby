# Changelog — yrby-rails

All notable changes to the `yrby-rails` gem (formerly `yrby-actioncable`) are
documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Log each causal-gap resync at `info` (`[yrby] causal-gap resync ...`, with the
  document key and `sync_log_context`). The reject path was otherwise silent, so
  there was no way to see how often clients force a resync. Override
  `sync_log_gap_resync` to change the level or silence it.

## [0.5.0] - 2026-08-05

### Added

- `Y::EncryptedDocument` / `Y::EncryptedDocumentUpdate`: document storage
  encrypted with Active Record encryption (`state` and update payloads),
  on the same tables — the class you access through decides the
  cryptography, the way `ActionText::EncryptedRichText` does. Point a
  channel's `on_load`/`on_change` (or a record association) at
  `Y::EncryptedDocument` and configure the app's encryption keys. Keep
  one access path per document: rows written encrypted read back as
  ciphertext through the plain classes. Ciphertext is larger than the
  plaintext, so the effective payload cap is roughly three quarters of
  the column limit.

## [0.4.0] - 2026-08-04

### Changed

- **The gem is now `yrby-rails`** (formerly `yrby-actioncable`) and a Rails
  engine. `yrby-actioncable` stops at 0.3.1; `yrby-rails` starts at 0.4.0.
  `Y::ActionCable` keeps its name as the public channel concern.

### Added

- `Y::Document`, engine-owned: a unique transport `key`, an optional
  polymorphic `record` + `name` binding, and the compacted `state`
  snapshot. It stores CRDT state only; derived data (rendered HTML,
  search text) is the application's job. `load_state(key)` /
  `append(key, update)` are the store calls the generated channel uses;
  `locate`/`locate!` find by key.
- `Y::DocumentUpdate`, engine-owned: the uncompacted tail, one delta per
  row, compacted into `state` and deleted at the threshold. A load reads
  the snapshot plus the current tail. Compaction serializes on a
  per-document row lock. Causally-gapped updates
  are quarantined (`pending`), excluded from the compaction trigger, and
  kept until they heal; a healed gap serves immediately and compacts away
  on the next pass.
- `Y::Document.for(record, name)` finds or creates a record's document,
  derives its key (`post/1/body`), and adopts a key-only row already
  holding that key, so a channel writing first and a binding created
  later end up on one row.
- `rails g yrby:tables` creates both tables. It is invoked by
  `yrby:install` and usable directly by gems building on the same
  storage.
- `include Y::ActionCable` now includes `Y::ActionCable::Sync` for you;
  the long spelling keeps working.
- `rails generate yrby:install`: a `DocumentChannel` speaking the
  y-websocket protocol over the gem-owned storage, plus the storage
  migration.

## [0.3.1] - 2026-07-01

### Removed

- The unhealable-gap strike defense that shipped in 0.3.0. That release was
  published prematurely, before the feature had been reviewed; 0.3.1 supersedes
  it with the defense removed while review happens. 0.3.0 remains installable
  and functional; the feature returns in a future release once reviewed.

## [0.3.0] - 2026-07-01

Published prematurely (see 0.3.1): shipped the unhealable-gap strike defense
(settle + drop a repeatedly-gapped update, `{ "ack" => id, "dropped" => true }`,
`gap_strike_limit`, istate-backed strikes under AnyCable) alongside the fixes
below. The fixes carry forward; the defense was withdrawn in 0.3.1 pending
review.

Fixes from a full source review:

### Fixed

- **A lost-ack retry now re-broadcasts.** If the original attempt recorded the
  update and then crashed (or the pub/sub broadcast failed) before
  distributing, the retry was previously settled as `:applied` without
  re-broadcasting — live subscribers stayed stale until their next full resync,
  and nothing else could reach them. The retry now re-broadcasts before acking;
  idempotent CRDT apply makes the duplicate free for every receiver.
- **A missing document key now fails closed.** Under a transport that doesn't
  keep the channel instance alive across actions (AnyCable), an app that forgot
  to pass `key` to `sync_receive` silently recorded updates under a nil key,
  broadcast them to a stream no one subscribes to, and still acked them. The
  frame now raises `Y::Error` instead.

### Changed

- Raised the `yrby` floor to `>= 0.3.1`, whose `update_ready?` is exact
  (trial-integration, not just per-client clocks). With an older core, a
  cross-client-origin gap passed the ready check and the `update_advances?`
  probe then acked-and-dropped real content.

## [0.2.3] - 2026-07-01

### Changed
- Raised the `yrby` floor to `>= 0.3.0`. That release makes
  `Doc#handle_sync_message` answer `SyncStep1` with integrated-only (gap-free)
  state — it no longer serves un-integrable pending structs, which previously
  poisoned peers and drove endless resync traffic. The sync channel serves its
  SyncStep2 response through that method, so with an older core a poisoned server
  store would still hand the gap to clients. No code change here — pinning the
  floor makes gap-free serving self-enforcing instead of dependent on the app
  updating the core gem.

## [0.2.2] - 2026-07-01

### Changed
- Raised the `yrby` floor to `>= 0.2.3`. That release makes `Doc#update_advances?`
  exact for **delete-bearing** updates. The sync channel gates durable
  record-before-distribute on `update_advances?` (`return :applied unless
  doc.update_advances?(update)`), so with an older core a lost-ack retry of a
  deletion the server had already integrated was re-recorded and re-broadcast
  each time. No code change here — pinning the floor just makes the gem's
  exactly-once durable-recording guarantee self-enforcing instead of dependent on
  the app updating the core gem.

## [0.2.1] - 2026-06-29

### Changed
- **Internal:** ActionCable stream-name prefix `y_ruby:` → `yrby:`.
  Server-internal (broadcast + `stream_from` both use it) — no public API or
  client-facing wire change. Depends on `yrby >= 0.2.1`.

## [0.2.0] - 2026-06-28

First release. The y-websocket sync channel concern is **`Y::ActionCable::Sync`**,
loaded with `require "y/action_cable"`. Depends on `yrby >= 0.2.0`.

### Notes
- Full y-websocket protocol over ActionCable/AnyCable: origin-filtered relay,
  awareness, on_load/on_save persistence hooks, optional record-before-distribute
  audit mode, and AnyCable `sync_backend :store`.
