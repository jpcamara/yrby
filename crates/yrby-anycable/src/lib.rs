//! yrby's collaborative-document channel for an AnyCable backend in Rust.
//!
//! [`DocumentChannel`] is the Rust counterpart of yrby-rails'
//! `Y::DocumentChannel`, so the browser side is yrby-client, unchanged,
//! pointed at anycable-go. The document logic is `yrby-core`'s
//! [`DocumentEngine`]; this crate connects it to anycable-go:
//!
//! - A client subscribes to `Y::DocumentChannel` with `{grant, name}`. The
//!   grant decides the document, and anycable-go keeps the document key in
//!   subscription state, out of the client's reach.
//! - Changes are relayed on the stream `yrby:<key>`.
//! - Awareness (cursors, presence) goes client to client as anycable-go
//!   whispers on `yrby:<key>:awareness`, and never reaches the backend.

// README examples are living code: compile-checked on every cargo test.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
mod readme_examples {}

use std::sync::Arc;

use anycable_rpc::{Broadcaster, Channel, ChannelContext, ChannelError, Reply, async_trait};
use serde_json::Value;

pub use yrby_core::compaction;
pub use yrby_core::engine::{
    DEFAULT_MAX_FRAME_BYTES, DocumentAuthorizer, DocumentEngine, EngineError, Identity, Relay,
};
pub use yrby_core::grant::{self, GrantSigner};
pub use yrby_core::store::{self, DocumentStore, MemoryStore, StoreError};

/// The channel name yrby-client subscribes to by default.
pub const CHANNEL_NAME: &str = "Y::DocumentChannel";

// The subscription state that carries the authorized document key from
// subscribe to later messages. anycable-go holds it, so a client cannot forge it.
const KEY_STATE: &str = "authorized_document_key";

fn stream_name(key: &str) -> String {
    format!("yrby:{key}")
}

fn awareness_stream_name(key: &str) -> String {
    format!("yrby:{key}:awareness")
}

/// The connection's identity, from anycable-go's connection identifiers.
pub fn identity(ctx: &ChannelContext) -> Identity {
    Identity::new(ctx.connection_identifiers.clone())
}

// The engine's relay, as broadcasts on the document's stream.
struct StreamRelay(Arc<dyn Broadcaster>);

#[async_trait]
impl Relay for StreamRelay {
    async fn relay(&self, key: &str, message: String) -> Result<(), EngineError> {
        self.0.broadcast(&stream_name(key), message).await
    }
}

/// The collaborative-document channel. Register it on an
/// [`anycable_rpc::Cable`] as [`CHANNEL_NAME`].
pub struct DocumentChannel {
    engine: DocumentEngine,
}

impl DocumentChannel {
    pub fn new(
        store: Arc<dyn DocumentStore>,
        broadcaster: Arc<dyn Broadcaster>,
        authorizer: Arc<dyn DocumentAuthorizer>,
    ) -> Self {
        let relay = Arc::new(StreamRelay(broadcaster));
        Self {
            engine: DocumentEngine::new(store, relay, authorizer),
        }
    }

    /// See [`DocumentEngine::max_frame_bytes`].
    pub fn max_frame_bytes(mut self, bytes: Option<usize>) -> Self {
        self.engine = self.engine.max_frame_bytes(bytes);
        self
    }

    /// See [`DocumentEngine::on_gap`].
    pub fn on_gap(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.engine = self.engine.on_gap(hook);
        self
    }
}

#[async_trait]
impl Channel for DocumentChannel {
    async fn subscribed(
        &self,
        ctx: &ChannelContext,
        reply: &mut Reply,
    ) -> Result<(), ChannelError> {
        let (Some(grant), Some(name)) = (ctx.param("grant"), ctx.param("name")) else {
            reply.reject();
            return Ok(());
        };
        let Some(opened) = self.engine.open(&identity(ctx), grant, name).await? else {
            reply.reject();
            return Ok(());
        };
        // The document stream is never whisper-enabled. Whispers go to the
        // awareness stream only, so the client-to-client path carries
        // ephemeral presence and never document state.
        reply.stream_from(stream_name(&opened.key));
        reply.stream_from_with_whisper(awareness_stream_name(&opened.key));
        reply.transmit(opened.handshake);
        reply.set_state(KEY_STATE, opened.key);
        Ok(())
    }

    async fn receive(
        &self,
        ctx: &ChannelContext,
        data: Value,
        reply: &mut Reply,
    ) -> Result<(), ChannelError> {
        // No key means this message did not come through an authorized
        // subscription, so there is nothing to write to.
        let Some(key) = ctx.state(KEY_STATE) else {
            reply.stop_all_streams();
            reply.reject();
            return Ok(());
        };
        for message in self.engine.receive(key, &data).await? {
            reply.transmit(message);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
