# yrby-core

[yrby](https://github.com/jpcamara/yrby)'s rules for keeping Yjs documents on
a server, as plain Rust with no framework or transport attached. yrby stores
every change before anyone else sees it, and these are the decisions that
takes: what a client's frame is, whether an update can apply now or is
waiting on another, what the server can safely serve, and how a document's
log of updates folds into a snapshot without losing anything. The yrby Ruby
gem's native extension and yrby's Rust servers both use it.

## Usage

```toml
[dependencies]
yrby-core = "0.1"
```

```rust
use yrby_core::protocol::classify_message;

// 0 drops the frame; 1 is a sync request; 2 a document change; 3 presence.
assert_eq!(classify_message(&[]), 0);
```

`compaction::merged_state` and `compaction::plan` store a document as a
snapshot plus a log, as yrby-rails does: a load merges them, and a compaction
folds the log into the snapshot. An update whose dependency has not arrived
stays in the log, marked pending, until it can be folded.

## The engine

With the `engine` feature, `engine::DocumentEngine` is yrby's server loop
for any transport. A transport calls `open` when a client subscribes with a
grant, and `receive` for each message after that. The engine answers sync
requests from a `DocumentStore`, and stores each change, then relays it
through a `Relay`, then acknowledges it to its sender. Nothing is kept in
memory between calls.

`grant::GrantSigner` signs and verifies grants: HS256 JWTs that open one
attribute of one document for a limited time. yrby-rails verifies the same
grants.

[`yrby-anycable`](https://github.com/jpcamara/yrby/tree/main/crates/yrby-anycable)
runs the engine behind anycable-go.
