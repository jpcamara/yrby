//! Write an [AnyCable](https://anycable.io) RPC backend in Rust.
//!
//! anycable-go terminates the WebSockets and calls a backend over gRPC for
//! everything that needs application logic: accepting a connection,
//! subscribing to a channel, handling a message. This crate is that backend:
//!
//! - [`service`]: the gRPC service anycable-go calls (`--rpc_host`).
//! - [`Cable`] and [`Channel`]: ActionCable-style channels, so clients written
//!   for ActionCable (`@rails/actioncable`, `@anycable/web`) work unchanged.
//! - [`HttpBroadcaster`]: publishing to streams through anycable-go.
//!
//! ```no_run
//! use anycable_rpc::{Cable, Channel, ChannelContext, ChannelError, Reply, async_trait};
//!
//! struct ChatChannel;
//!
//! #[async_trait]
//! impl Channel for ChatChannel {
//!     async fn subscribed(&self, ctx: &ChannelContext, reply: &mut Reply) -> Result<(), ChannelError> {
//!         match ctx.param("room") {
//!             Some(room) => reply.stream_from(format!("chat:{room}")),
//!             None => reply.reject(),
//!         }
//!         Ok(())
//!     }
//! }
//!
//! # async fn run() -> Result<(), Box<dyn std::error::Error>> {
//! let cable = Cable::new().channel("ChatChannel", ChatChannel);
//! tonic::transport::Server::builder()
//!     .add_service(anycable_rpc::service(cable))
//!     .serve("127.0.0.1:50051".parse()?)
//!     .await?;
//! # Ok(()) }
//! ```

// README examples are living code: compile-checked on every cargo test.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
mod readme_examples {}

pub mod broadcast;
pub mod channel;
pub mod proto;
pub mod secret;
pub mod server;

pub use async_trait::async_trait;
pub use broadcast::{BroadcastError, Broadcaster, HttpBroadcaster};
pub use channel::{
    AllowAll, Authenticator, Cable, Channel, ChannelContext, ChannelError, Reply,
    WHISPER_STREAM_STATE,
};
pub use server::{RpcHandler, RpcMeta, Service, service};
