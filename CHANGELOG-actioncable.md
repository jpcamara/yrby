# Changelog — yrb-lite-actioncable

All notable changes to the `yrb-lite-actioncable` gem are documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0.beta2] - 2026-06-20

### Added

- `sync_whisper` channel option (default off). When enabled and running under
  AnyCable, the channel enables client-to-client whispering on its stream
  (`stream_from key, whisper: true`), so a client that opts into whisper delivery
  (the JS provider's `awarenessWhisper: true`) has its presence frames broadcast
  directly to other subscribers with no server round-trip. It has no effect on
  plain ActionCable (which has no whisper support), so presence there stays
  server-relayed. Document updates are never whispered.

## [0.1.0.beta1] - 2026-06-18

### Added

- Initial release, extracted from `yrb-lite` (which shipped this as
  `YrbLite::Sync` through 0.1.0.beta4). Provides `YrbLite::ActionCable::Sync`, an
  ActionCable channel concern implementing the y-websocket sync protocol and
  awareness/presence over ActionCable and AnyCable: record-before-distribute
  auditing (`on_change`), persistence hooks (`on_load`/`on_save`), `:memory` and
  `:store` backends, presence reaping, idle-document eviction, and multi-process
  replica sync. Depends on `yrb-lite` (>= 0.1.0.beta5) for the CRDT documents,
  awareness, and protocol primitives.
- `on_change` recorders run in the channel instance's context (carried over from
  `yrb-lite` 0.1.0.beta4), so a recorder can call the channel's own methods
  directly.

[Unreleased]: https://github.com/jpcamara/yrb-lite/commits/main
[0.1.0.beta2]: https://github.com/jpcamara/yrb-lite/commits/main
[0.1.0.beta1]: https://github.com/jpcamara/yrb-lite/releases/tag/v0.1.0.beta5
