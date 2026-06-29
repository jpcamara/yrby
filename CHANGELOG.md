# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-28

First release under the **`yrby`** name (the project was previously developed
as `yrb-lite`). The public Ruby interface is the top-level module **`Y`** —
mirroring the `y-rb` gem's `Y::Doc` interface.

### Changed
- **Renamed `yrb-lite` → `yrby`.** Module `YrbLite` → top-level `Y`
  (`Y::Doc`, `Y::Error`, `Y::VERSION`). Require path `require "yrb_lite"` →
  `require "y"`. Native extension crate `yrb_lite` → `y_ruby`, loaded from
  `lib/y/y_ruby.bundle`.

### Added
- Native `Doc#read_text` and `Doc#read_map` readers — reconstruct plain text and
  a JSON map from the stored CRDT state in-process, server-side, with no Node or
  subprocess.

### Notes
- y-crdt wrapper over Rust `yrs` 0.27.2 (magnus/rb-sys), with the full
  y-websocket sync protocol + Awareness, thread-safe (`Send`/`Sync`,
  GVL released around CRDT work). Precompiled platform gems are published
  alongside the source gem so `gem install yrby` needs no Rust toolchain.
