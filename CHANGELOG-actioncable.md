# Changelog — yrby-actioncable

All notable changes to the `yrby-actioncable` gem are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
