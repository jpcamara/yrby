# Changelog — yrby-actioncable

All notable changes to the `yrby-actioncable` gem are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `causal_gap_policy` channel option (default `:reject`, preserving current
  behavior) with three settings for how a causally-gapped update is handled:
  - `:reject` — the current behavior: don't record it, ask the sender to resync.
  - `:accept_strict` — record it (durable on arrival) but withhold the ack until
    it integrates, so the sender keeps retransmitting and an open gap
    self-signals as retry traffic.
  - `:accept` — record and ack it immediately (ack-on-durable) via an inverted
    write path that doesn't rebuild the document; dedup is delegated to the
    store's idempotency. Fastest, and an open gap is repaired via the join
    handshake rather than a resend.

  Serving stays gap-free under every policy. Accept modes require a lossless
  store (`on_load` must preserve pending; compaction guarded with `doc.pending?`)
  and, being quiet about an open gap, add:
  - a **repair loop**: when a client joins or syncs and a gap is open, the server
    solicits the missing dependency from that client (any live client that has it
    heals the gap);
  - an **`on_gap` observability hook**, fired with the document key when a gap is
    observed, plus an `info` log, so an unhealed gap is visible (accept modes heal
    silently, replacing reject mode's resync-storm signal).
- `Doc#update_adds_content?` — true if an update adds any content (integrated or
  pending) the doc doesn't already hold. Unlike `update_advances?` it stays
  correct when the doc already holds pending, so a gap-storing caller can tell a
  fresh gap from a duplicate retry. (`yrby` core.)

Proposal / RFC — the policy defaults to `:reject`, so nothing changes unless you
opt in. See the "Accepting causal gaps" section of the README.

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
