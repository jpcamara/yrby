# anycable-rpc

Write an [AnyCable](https://anycable.io) backend in Rust.

`anycable-go` holds the WebSocket connections and calls a backend over gRPC
whenever a decision needs application logic: may this connection in, may it
subscribe to this channel, what should happen with this message. Until now
that backend has been Ruby (anycable-rails) or JavaScript. This crate lets it
be a Rust service.

It has three parts:

- `service`: the gRPC service anycable-go calls, generated from AnyCable's own
  `rpc.proto`, for a tonic server.
- `Cable` and `Channel`: channels in the ActionCable style, so clients written
  for ActionCable (`@rails/actioncable`, `@anycable/web`) work unchanged. A
  channel streams, transmits, rejects, keeps per-subscription state, and can
  let clients whisper to each other without a call to the backend.
- `HttpBroadcaster`: publishes to streams through anycable-go's HTTP
  broadcaster.

## Usage

```toml
[dependencies]
anycable-rpc = "0.1"
tokio = { version = "1", features = ["full"] }
tonic = "0.14"
```

```rust,no_run
use anycable_rpc::{async_trait, Cable, Channel, ChannelContext, ChannelError, Reply};
use serde_json::Value;

struct ChatChannel;

#[async_trait]
impl Channel for ChatChannel {
    async fn subscribed(&self, ctx: &ChannelContext, reply: &mut Reply) -> Result<(), ChannelError> {
        match ctx.param("room") {
            Some(room) => {
                reply.stream_from(format!("chat:{room}"));
                reply.set_state("room", room);
            }
            None => reply.reject(),
        }
        Ok(())
    }

    async fn receive(&self, ctx: &ChannelContext, data: Value, reply: &mut Reply) -> Result<(), ChannelError> {
        // State set at subscribe comes back with every message.
        let room = ctx.state("room").unwrap_or_default();
        reply.transmit(serde_json::json!({ "room": room, "echo": data }));
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cable = Cable::new().channel("ChatChannel", ChatChannel);
    tonic::transport::Server::builder()
        .add_service(anycable_rpc::service(cable))
        .serve("127.0.0.1:50051".parse()?)
        .await?;
    Ok(())
}
```

Then run anycable-go against it:

```sh
anycable-go --rpc_host=127.0.0.1:50051
```

A browser subscribes as it would to Rails:

```js
import { createConsumer } from "@anycable/web";

createConsumer("ws://localhost:8080/cable").subscriptions.create(
  { channel: "ChatChannel", room: "lobby" },
  { received: (message) => console.log(message) },
);
```

## Connections

By default every connection is accepted with no identifiers. Implement
`Authenticator` to decide, as an ActionCable `Connection#connect` would; the
identifiers it returns come back with every command as
`ChannelContext::connection_identifiers`. anycable-go can also identify
connections itself, from a JWT in the URL, with no call to the backend at all.

## Broadcasting

```rust,no_run
use anycable_rpc::{Broadcaster, HttpBroadcaster};

# async fn run() -> Result<(), anycable_rpc::BroadcastError> {
let broadcaster = HttpBroadcaster::new("http://127.0.0.1:8080/_broadcast")
    .with_key(anycable_rpc::secret::broadcast_key("anycable-go's --secret"));
broadcaster.broadcast("chat:lobby", r#"{"text":"hello"}"#.to_string()).await?;
# Ok(()) }
```

## Security

anycable-go's gRPC calls carry no credentials, as with AnyCable's Ruby RPC
server. Listen on an address only anycable-go can reach.

## Building

The gRPC code is generated from `proto/rpc.proto` at build time. `protoc`
comes from the `protoc-bin-vendored` crate, so it does not need to be
installed.
