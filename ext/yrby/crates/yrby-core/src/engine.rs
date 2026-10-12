//! The server side of a yrby document, for any transport.
//!
//! A transport (anycable-go's RPC, a WebSocket route, a test harness) owns
//! the connections. For each subscription it calls [`DocumentEngine::open`]
//! once, and [`DocumentEngine::receive`] for every message after that. The
//! engine never holds a document between calls: it loads from the
//! [`DocumentStore`] whenever it serves state, so any process can serve any
//! document.
//!
//! The messages are yrby's JSON envelope around y-protocols frames, in base64:
//! `{update, id}` from a client, `{update}` to subscribers, and `{ack: id}`
//! back to the sender once its change is stored and relayed.

use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, ReadTxn, Transact, Update};

use crate::grant::GrantSigner;
use crate::protocol;
use crate::store::DocumentStore;

pub type EngineError = Box<dyn std::error::Error + Send + Sync>;

/// Largest incoming frame, in decoded bytes, unless configured otherwise:
/// room for a large first SyncStep2, small enough to bound one message's cost.
pub const DEFAULT_MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// Who is on the other end of a connection, as the transport identified them:
/// for anycable-go, its connection identifiers.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Identity {
    pub identifiers: Value,
}

impl Identity {
    pub fn new(identifiers: Value) -> Self {
        Self { identifiers }
    }

    /// A string identifier, such as `get("user")`.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.identifiers.get(name).and_then(Value::as_str)
    }
}

/// Decides which document a subscription opens.
#[async_trait]
pub trait DocumentAuthorizer: Send + Sync + 'static {
    /// The document key the `grant` opens for attribute `name`, or `None` to
    /// refuse. `identity` is the connection's, for a policy that also checks
    /// the current user.
    async fn authorize(&self, identity: &Identity, grant: &str, name: &str) -> Option<String>;
}

#[async_trait]
impl DocumentAuthorizer for GrantSigner {
    async fn authorize(&self, _identity: &Identity, grant: &str, name: &str) -> Option<String> {
        self.verify(grant, name)
    }
}

/// Delivers a message to every subscriber of a document, the sender
/// included. Returns once the transport has accepted it.
#[async_trait]
pub trait Relay: Send + Sync + 'static {
    async fn relay(&self, key: &str, message: String) -> Result<(), EngineError>;
}

/// A subscription the engine has accepted.
#[derive(Debug, Clone, PartialEq)]
pub struct Opened {
    /// The document the grant opened. Pass it to every later
    /// [`DocumentEngine::receive`], from state the client cannot change.
    pub key: String,
    /// The first message for the client: the server's SyncStep1, which also
    /// asks the client for anything the store is missing.
    pub handshake: Value,
}

type GapHook = Arc<dyn Fn(&str) + Send + Sync>;

/// yrby's sync loop. See the [module docs](self).
pub struct DocumentEngine {
    store: Arc<dyn DocumentStore>,
    relay: Arc<dyn Relay>,
    authorizer: Arc<dyn DocumentAuthorizer>,
    max_frame_bytes: Option<usize>,
    on_gap: Option<GapHook>,
}

// What a frame did, for the acknowledgment: only a recorded change is acked.
#[derive(Debug, PartialEq)]
enum Outcome {
    Recorded,
    Noop,
}

impl DocumentEngine {
    pub fn new(
        store: Arc<dyn DocumentStore>,
        relay: Arc<dyn Relay>,
        authorizer: Arc<dyn DocumentAuthorizer>,
    ) -> Self {
        Self {
            store,
            relay,
            authorizer,
            max_frame_bytes: Some(DEFAULT_MAX_FRAME_BYTES),
            on_gap: None,
        }
    }

    /// Drop frames larger than `bytes` once decoded; `None` removes the cap.
    /// A dropped update is never acked, so the client retries it forever:
    /// keep the cap above any legitimate update.
    pub fn max_frame_bytes(mut self, bytes: Option<usize>) -> Self {
        self.max_frame_bytes = bytes;
        self
    }

    /// Called with the document key whenever a served document still holds a
    /// causal gap (an update whose dependency has not arrived). Use it for a
    /// metric, so a gap that never heals is visible.
    pub fn on_gap(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.on_gap = Some(Arc::new(hook));
        self
    }

    /// Open the document `grant` names, as attribute `name`, for `identity`.
    /// `None` refuses the subscription.
    pub async fn open(
        &self,
        identity: &Identity,
        grant: &str,
        name: &str,
    ) -> Result<Option<Opened>, EngineError> {
        let Some(key) = self.authorizer.authorize(identity, grant, name).await else {
            tracing::info!(name, "[yrby] subscription rejected");
            return Ok(None);
        };
        // The opening handshake is also the gap-repair prompt: our SyncStep1
        // asks the joining client for everything beyond the stored state,
        // which includes whatever an open gap is waiting on.
        let doc = self.load_doc(&key).await?;
        let step1 =
            Message::Sync(SyncMessage::SyncStep1(doc.transact().state_vector())).encode_v1();
        self.observe_gap(&key, &doc);
        Ok(Some(Opened {
            key,
            handshake: envelope(&step1),
        }))
    }

    /// Handle one message from a client subscribed to `key`. Returns the
    /// messages for that client alone: a sync reply, an acknowledgment, or
    /// nothing. Changes for everyone go out through the [`Relay`].
    ///
    /// An error means the message was not handled: a change was neither
    /// relayed nor acknowledged, and the client will send it again.
    pub async fn receive(&self, key: &str, data: &Value) -> Result<Vec<Value>, EngineError> {
        let Some(encoded) = data.get("update").and_then(Value::as_str) else {
            return Ok(Vec::new());
        };
        let id = data.get("id").filter(|id| !id.is_null());

        // Drop an oversized frame before decoding it (base64 is about 4/3 the
        // decoded size) and again after.
        if let Some(cap) = self.max_frame_bytes
            && encoded.len() > cap * 4 / 3 + 4
        {
            tracing::warn!(
                key,
                ?id,
                "[yrby] dropped frame: encoded {}B exceeds max_frame_bytes {cap}B",
                encoded.len()
            );
            return Ok(Vec::new());
        }
        let Ok(bytes) = STANDARD.decode(encoded) else {
            tracing::debug!(key, ?id, "[yrby] dropped frame: not valid base64");
            return Ok(Vec::new());
        };
        if let Some(cap) = self.max_frame_bytes
            && bytes.len() > cap
        {
            tracing::warn!(
                key,
                ?id,
                "[yrby] dropped frame: decoded {}B exceeds max_frame_bytes {cap}B",
                bytes.len()
            );
            return Ok(Vec::new());
        }

        let mut replies = Vec::new();
        let outcome = self
            .handle_frame(key, encoded, &bytes, &mut replies)
            .await?;
        // Acked only once recorded and relayed. The ack goes to the sender alone.
        if let (Some(id), Outcome::Recorded) = (id, outcome) {
            replies.push(json!({ "ack": id }));
        }
        Ok(replies)
    }

    async fn load_doc(&self, key: &str) -> Result<Doc, EngineError> {
        let doc = Doc::new();
        if let Some(state) = self.store.load(key).await? {
            doc.transact_mut()
                .apply_update(Update::decode_v1(&state)?)?;
        }
        Ok(doc)
    }

    fn observe_gap(&self, key: &str, doc: &Doc) {
        if !protocol::has_pending(doc) {
            return;
        }
        tracing::info!(
            key,
            "[yrby] causal gap present (pending until its dependency arrives)"
        );
        if let Some(hook) = &self.on_gap {
            hook(key);
        }
    }

    async fn distribute(&self, key: &str, encoded: &str) -> Result<(), EngineError> {
        self.relay
            .relay(key, json!({ "update": encoded }).to_string())
            .await
    }

    async fn handle_frame(
        &self,
        key: &str,
        encoded: &str,
        bytes: &[u8],
        replies: &mut Vec<Value>,
    ) -> Result<Outcome, EngineError> {
        match protocol::classify_message(bytes) {
            // SyncStep1: answer with everything the client lacks, from the store.
            1 => {
                let Ok(Message::Sync(SyncMessage::SyncStep1(sv))) = Message::decode_v1(bytes)
                else {
                    return Ok(Outcome::Noop);
                };
                let doc = self.load_doc(key).await?;
                // Full state, pending included, as Yjs' encodeStateAsUpdate
                // does. A peer parks a pending struct and heals it the same way.
                let update = doc.transact().encode_state_as_update_v1(&sv);
                replies.push(envelope(
                    &Message::Sync(SyncMessage::SyncStep2(update)).encode_v1(),
                ));
                self.observe_gap(key, &doc);
                Ok(Outcome::Noop)
            }
            // A document change: record, then relay, then (in the caller) ack.
            2 => match protocol::merged_doc_update(bytes) {
                Ok(Some(update)) => {
                    self.store.append(key, &update).await?;
                    self.distribute(key, encoded).await?;
                    Ok(Outcome::Recorded)
                }
                Ok(None) => Ok(Outcome::Noop),
                Err(error) => {
                    tracing::debug!(key, %error, "[yrby] dropped frame: unreadable update");
                    Ok(Outcome::Noop)
                }
            },
            // Awareness sent as a message, by a client or transport with no
            // client-to-client path: relay it, never store it.
            3 => {
                self.distribute(key, encoded).await?;
                Ok(Outcome::Noop)
            }
            _ => Ok(Outcome::Noop),
        }
    }
}

fn envelope(frame: &[u8]) -> Value {
    json!({ "update": STANDARD.encode(frame) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;
    use std::sync::Mutex;
    use yrs::{GetString, Text};

    #[derive(Default)]
    struct Recorder(Mutex<Vec<(String, String)>>);

    #[async_trait]
    impl Relay for Recorder {
        async fn relay(&self, key: &str, message: String) -> Result<(), EngineError> {
            self.0.lock().unwrap().push((key.to_string(), message));
            Ok(())
        }
    }

    // The engine with no transport at all: open, edit, sync, as a WebSocket
    // route or any other transport would drive it.
    #[tokio::test]
    async fn drives_a_document_without_a_transport() {
        let store = Arc::new(MemoryStore::new());
        let relay = Arc::new(Recorder::default());
        let signer = GrantSigner::new("secret");
        let engine = DocumentEngine::new(store.clone(), relay.clone(), Arc::new(signer.clone()));
        let identity = Identity::new(json!({ "user": "ada" }));
        assert_eq!(identity.get("user"), Some("ada"));

        assert_eq!(
            engine.open(&identity, "forged", "body").await.unwrap(),
            None
        );
        let opened = engine
            .open(&identity, &signer.sign("doc-1", "body", 60), "body")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(opened.key, "doc-1");
        let step1 = STANDARD
            .decode(opened.handshake["update"].as_str().unwrap())
            .unwrap();
        assert_eq!(protocol::classify_message(&step1), 1);

        let doc = Doc::new();
        let text = doc.get_or_insert_text("t");
        let update = {
            let mut txn = doc.transact_mut();
            text.insert(&mut txn, 0, "hello");
            txn.encode_update_v1()
        };
        let frame = STANDARD.encode(Message::Sync(SyncMessage::Update(update)).encode_v1());
        let replies = engine
            .receive("doc-1", &json!({ "update": frame, "id": 3 }))
            .await
            .unwrap();
        assert_eq!(replies, vec![json!({ "ack": 3 })]);
        assert_eq!(store.len("doc-1"), 1);
        assert_eq!(relay.0.lock().unwrap()[0].0, "doc-1");

        let client_step1 =
            Message::Sync(SyncMessage::SyncStep1(Doc::new().transact().state_vector())).encode_v1();
        let replies = engine
            .receive("doc-1", &json!({ "update": STANDARD.encode(client_step1) }))
            .await
            .unwrap();
        let reply = STANDARD
            .decode(replies[0]["update"].as_str().unwrap())
            .unwrap();
        let Message::Sync(SyncMessage::SyncStep2(state)) = Message::decode_v1(&reply).unwrap()
        else {
            panic!("expected SyncStep2");
        };
        let served = Doc::new();
        served
            .transact_mut()
            .apply_update(Update::decode_v1(&state).unwrap())
            .unwrap();
        let text = served.get_or_insert_text("t");
        assert_eq!(text.get_string(&served.transact()), "hello");
    }
}
