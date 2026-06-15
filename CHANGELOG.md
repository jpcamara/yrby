# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Thread-safe `YrbLite::Doc` and `YrbLite::Awareness` over `yrs` (magnus/rb-sys
  native extension). The GVL is released during CRDT work so docs can run in
  parallel on MRI.
- `YrbLite::Sync` ActionCable channel concern implementing the y-websocket
  protocol (document sync plus awareness/presence). It's wire-compatible with
  the [`@y-rb/actioncable`](https://www.npmjs.com/package/@y-rb/actioncable)
  browser provider, and accepts its `{ update: ... }` envelope and `{ m: ... }`.
- A "record-before-distribute" mode via an `on_change` hook, so every change is
  recorded durably before it's applied or relayed.
- Presence cleanup on disconnect, and idle-document eviction.
- Two backends: `sync_backend :memory` (default, classic ActionCable) and
  `sync_backend :store` (stateless, AnyCable-ready, multi-process).
- Hardening against bad input: malformed or multi-message frames are dropped
  before processing or relay, and native panics are contained at the FFI
  boundary.
- Precompiled native gems for common platforms (no Rust toolchain needed to
  install) via the cross-gem workflow.

[Unreleased]: https://github.com/jpcamara/yrb-lite/commits/main
