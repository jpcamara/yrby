# yrby's Rust crates

yrby's server side in Rust, for apps that run
[AnyCable](https://anycable.io) in front of a Rust backend. The browser runs
the same `yrby-client` package it does with Rails.

| Crate | What it is |
|---|---|
| [`yrby-core`](../ext/yrby/crates/yrby-core) | yrby's sync and storage rules, and a document engine for any transport. Shared with the Ruby gem's native extension, which is why it lives under `ext/`. |
| [`anycable-rpc`](anycable-rpc) | A Rust backend for anycable-go: its gRPC service, ActionCable-style channels, and an HTTP broadcaster. Not specific to yrby. |
| [`yrby-anycable`](yrby-anycable) | yrby's collaborative-document channel on `anycable-rpc`, for any Rust web framework. |
| [`loco-yrby`](loco-yrby) | yrby for [Loco](https://loco.rs) apps: an initializer, a database store with yrby-rails' schema, compaction, and encryption, grants, and connection identity. |

```text
loco-yrby -> yrby-anycable -> anycable-rpc
     \             \
      `-> yrby-core <-' (also the Ruby gem's extension)
```

The document logic is `yrby-core`'s engine, which knows nothing about
AnyCable. `yrby-anycable` is one transport for it; another (a plain
WebSocket route, say) would be a second adapter, not a second copy of the
logic.

## Tests

```sh
cargo test                               # everything, documents on SQLite
YRBY_TEST_POSTGRES_URL=postgres://user:pass@localhost:5432/postgres \
  cargo test -p loco-yrby                # the store again, on Postgres
```

The Postgres tests create a database per test (named `yrby_test_*`), so the
URL needs a user that may create databases.

The end-to-end suites drive the real browser client through anycable-go,
against the `yrby-anycable` demo and against `examples/loco-demo`. See
[`packages/client/e2e`](../packages/client/e2e).

Minimum Rust: 1.88 for `anycable-rpc`, 1.95 for the others (yrs 0.27.4 needs
it).
