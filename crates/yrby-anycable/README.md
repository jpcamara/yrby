# yrby-anycable

[yrby](https://github.com/jpcamara/yrby)'s collaborative-document channel for
an [AnyCable](https://anycable.io) backend written in Rust, with any web
framework. It is the Rust counterpart of yrby-rails' `Y::DocumentChannel`, so
the browser side is the `yrby-client` package, unchanged, connected to
anycable-go. The document logic is
[`yrby-core`](../../ext/yrby/crates/yrby-core)'s engine; this crate connects it
to anycable-go's channels, streams, and whispers.

What the channel does:

- The client subscribes to `Y::DocumentChannel` with a grant and an attribute
  name. The grant decides the document; the client never names one.
- It speaks yrby's protocol: Yjs sync messages in a JSON envelope, with
  acknowledgments to the sender.
- Every change is stored before it is relayed, and relayed before it is
  acknowledged. No document lives in memory between calls, so any process can
  serve any document.
- Presence (cursors, selections) goes from client to client as anycable-go
  whispers and never reaches the backend.

You supply three things:

- A `DocumentStore`: where documents live. `MemoryStore` is for tests and
  demos; [`loco-yrby`](../loco-yrby) has a database store with compaction.
- A `Broadcaster` from [`anycable-rpc`](../anycable-rpc), to relay changes.
- A `DocumentAuthorizer`: which document a grant opens. `GrantSigner`
  verifies signed, expiring grants (JWTs) and is one.

## Usage

```rust,no_run
use std::sync::Arc;

use anycable_rpc::{Cable, HttpBroadcaster};
use yrby_anycable::{DocumentChannel, GrantSigner, MemoryStore, CHANNEL_NAME};

# async fn run() -> Result<(), Box<dyn std::error::Error>> {
let signer = GrantSigner::new("a secret only grants use");
let channel = DocumentChannel::new(
    Arc::new(MemoryStore::new()),
    Arc::new(HttpBroadcaster::new("http://127.0.0.1:8080/_broadcast")),
    Arc::new(signer.clone()),
);
let cable = Cable::new().channel(CHANNEL_NAME, channel);
tonic::transport::Server::builder()
    .add_service(anycable_rpc::service(cable))
    .serve("127.0.0.1:50051".parse()?)
    .await?;
# Ok(()) }
```

The page gets a grant for its document from the app, `signer.sign(key, "body",
ttl_seconds)`, and hands it to the client:

```js
const lease = DocumentSessionStore.for(consumer).acquire({ grant, name: "body" });
```

## Grants

A grant is an HS256 JWT:

```json
{ "aud": "yrby", "sub": "<document>", "name": "body", "exp": 1790000000 }
```

`name` scopes it to one attribute, `aud` keeps it from passing for any other
kind of token, and it must expire. yrby-rails verifies and mints the same
grants (`config.yrby.grant_secret`), so a Rails app and a Rust app can accept
each other's.

## Storage

`compaction` holds the storage rules a database store needs, as pure
functions: merging a snapshot with its update log on load, and planning a
compaction that folds the log into the snapshot. An update whose dependency
has not arrived yet stays in the log, marked pending, until it can be folded.
These are yrby-rails' rules.

## Demo

`examples/demo.rs` serves the channel with an in-memory store, plus a small
HTTP API that mints grants and inspects documents for the end-to-end tests:

```sh
cargo run -p yrby-anycable --example demo
anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http
```
