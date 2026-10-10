// The channel driven through Cable, as anycable-go's RPC calls reach it.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anycable_rpc::proto::{CommandMessage, CommandResponse, Env, Status};
use anycable_rpc::{BroadcastError, Cable, RpcHandler, RpcMeta, WHISPER_STREAM_STATE};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::json;
use yrby_core::protocol;
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, GetString, ReadTxn, Text, Transact, Update};

use super::*;

const SECRET: &str = "test-secret";

/// Records broadcasts, and how many updates the store held at each one.
struct Recorder {
    store: Arc<MemoryStore>,
    sent: Mutex<Vec<(String, String, usize)>>,
    fail: AtomicBool,
}

#[async_trait]
impl Broadcaster for Recorder {
    async fn broadcast(&self, stream: &str, data: String) -> Result<(), BroadcastError> {
        if self.fail.load(Ordering::SeqCst) {
            return Err("anycable-go unreachable".into());
        }
        let stored = self.store.len("doc-1");
        self.sent
            .lock()
            .unwrap()
            .push((stream.to_string(), data, stored));
        Ok(())
    }
}

/// A store whose appends can be made to fail.
struct Flaky {
    inner: Arc<MemoryStore>,
    fail: AtomicBool,
}

#[async_trait]
impl DocumentStore for Flaky {
    async fn load(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError> {
        self.inner.load(key).await
    }
    async fn append(&self, key: &str, update: &[u8]) -> Result<(), StoreError> {
        if self.fail.load(Ordering::SeqCst) {
            return Err("disk full".into());
        }
        self.inner.append(key, update).await
    }
}

struct Harness {
    cable: Cable,
    memory: Arc<MemoryStore>,
    store: Arc<Flaky>,
    broadcasts: Arc<Recorder>,
    gaps: Arc<Mutex<Vec<String>>>,
    identifier: String,
}

impl Harness {
    fn new() -> Self {
        let memory = Arc::new(MemoryStore::new());
        let store = Arc::new(Flaky {
            inner: memory.clone(),
            fail: AtomicBool::new(false),
        });
        let broadcasts = Arc::new(Recorder {
            store: memory.clone(),
            sent: Mutex::default(),
            fail: AtomicBool::new(false),
        });
        let gaps = Arc::new(Mutex::new(Vec::new()));
        let seen = gaps.clone();
        let channel = DocumentChannel::new(
            store.clone(),
            broadcasts.clone(),
            Arc::new(GrantSigner::new(SECRET)),
        )
        .max_frame_bytes(Some(1024))
        .on_gap(move |key| seen.lock().unwrap().push(key.to_string()));
        let grant = GrantSigner::new(SECRET).sign("doc-1", "body", 60);
        let identifier = identifier(&grant, "body");
        Self {
            cable: Cable::new().channel(CHANNEL_NAME, channel),
            memory,
            store,
            broadcasts,
            gaps,
            identifier,
        }
    }

    async fn subscribe(&self, identifier: &str) -> CommandResponse {
        self.call("subscribe", identifier, "", &[]).await
    }

    /// A message on the subscription made by `subscribe` (its state carries the key).
    async fn send(&self, data: Value) -> CommandResponse {
        self.call(
            "message",
            &self.identifier,
            &data.to_string(),
            &[(KEY_STATE, "doc-1")],
        )
        .await
    }

    async fn call(
        &self,
        command: &str,
        identifier: &str,
        data: &str,
        istate: &[(&str, &str)],
    ) -> CommandResponse {
        let istate: HashMap<String, String> = istate
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let message = CommandMessage {
            command: command.into(),
            identifier: identifier.into(),
            connection_identifiers: "{}".into(),
            data: data.into(),
            env: Some(Env {
                istate,
                ..Default::default()
            }),
        };
        self.cable.command(&RpcMeta::default(), message).await
    }

    fn broadcasts(&self) -> Vec<(String, String, usize)> {
        self.broadcasts.sent.lock().unwrap().clone()
    }
}

fn identifier(grant: &str, name: &str) -> String {
    json!({ "channel": CHANNEL_NAME, "grant": grant, "name": name, "session_id": "s-1" })
        .to_string()
}

fn messages(response: &CommandResponse) -> Vec<Value> {
    response
        .transmissions
        .iter()
        .map(|t| serde_json::from_str::<Value>(t).unwrap())
        .collect()
}

fn b64(frame: &[u8]) -> String {
    STANDARD.encode(frame)
}

/// A client edit, as the y-protocols Update frame a browser would send.
fn edit(text: &str) -> (Vec<u8>, Vec<u8>) {
    let doc = Doc::new();
    // Get the text before opening the transaction: yrs blocks on a nested one.
    let content = doc.get_or_insert_text("t");
    let update = {
        let mut txn = doc.transact_mut();
        content.insert(&mut txn, 0, text);
        txn.encode_update_v1()
    };
    (
        Message::Sync(SyncMessage::Update(update.clone())).encode_v1(),
        update,
    )
}

fn text_of(state: &[u8]) -> String {
    let doc = Doc::new();
    doc.transact_mut()
        .apply_update(Update::decode_v1(state).unwrap())
        .unwrap();
    let text = doc.get_or_insert_text("t");
    text.get_string(&doc.transact())
}

#[tokio::test]
async fn subscribes_with_streams_state_and_a_handshake() {
    let h = Harness::new();
    let response = h.subscribe(&h.identifier).await;

    assert_eq!(response.status(), Status::Success);
    assert_eq!(response.streams, vec!["yrby:doc-1", "yrby:doc-1:awareness"]);
    let istate = &response.env.as_ref().unwrap().istate;
    assert_eq!(istate[KEY_STATE], "doc-1");
    // Whispers reach the awareness stream only, never the document stream.
    assert_eq!(istate[WHISPER_STREAM_STATE], "yrby:doc-1:awareness");

    let frames = messages(&response);
    let step1 = STANDARD
        .decode(frames[0]["message"]["update"].as_str().unwrap())
        .unwrap();
    assert_eq!(protocol::classify_message(&step1), 1);
    assert_eq!(frames[1]["type"], "confirm_subscription");
}

#[tokio::test]
async fn rejects_bad_grants() {
    let h = Harness::new();
    let signer = GrantSigner::new(SECRET);
    for identifier in [
        identifier("forged--00", "body"),
        identifier(&signer.sign("doc-1", "body", -5), "body"), // expired
        identifier(&signer.sign("doc-1", "body", 60), "title"), // another attribute
        identifier(&GrantSigner::new("other").sign("doc-1", "body", 60), "body"),
        json!({ "channel": CHANNEL_NAME }).to_string(),
    ] {
        let response = h.subscribe(&identifier).await;
        assert_eq!(response.status(), Status::Failure, "{identifier}");
        assert!(response.streams.is_empty());
        assert_eq!(
            messages(&response).last().unwrap()["type"],
            "reject_subscription"
        );
    }
}

#[tokio::test]
async fn records_then_relays_then_acks_an_update() {
    let h = Harness::new();
    let (frame, _) = edit("hello");
    let encoded = b64(&frame);
    let response = h.send(json!({ "update": encoded, "id": 7 })).await;

    assert_eq!(response.status(), Status::Success);
    assert_eq!(h.memory.len("doc-1"), 1);
    let broadcasts = h.broadcasts();
    assert_eq!(broadcasts.len(), 1);
    let (stream, data, stored_at_broadcast) = &broadcasts[0];
    assert_eq!(stream, "yrby:doc-1");
    assert_eq!(
        serde_json::from_str::<Value>(data).unwrap(),
        json!({ "update": encoded })
    );
    assert_eq!(*stored_at_broadcast, 1, "relayed before it was recorded");
    // The ack goes only to the sender, in this reply.
    assert_eq!(
        messages(&response),
        vec![json!({ "identifier": h.identifier, "message": { "ack": 7 } })]
    );

    let state = h.memory.load("doc-1").await.unwrap().unwrap();
    assert_eq!(text_of(&state), "hello");
}

#[tokio::test]
async fn a_failed_store_neither_relays_nor_acks() {
    let h = Harness::new();
    h.store.fail.store(true, Ordering::SeqCst);
    let (frame, _) = edit("lost");
    let response = h.send(json!({ "update": b64(&frame), "id": 1 })).await;

    assert_eq!(response.status(), Status::Error);
    assert!(h.broadcasts().is_empty());
    assert!(response.transmissions.is_empty());
}

#[tokio::test]
async fn a_failed_broadcast_is_not_acked() {
    let h = Harness::new();
    h.broadcasts.fail.store(true, Ordering::SeqCst);
    let (frame, _) = edit("stored");
    let response = h.send(json!({ "update": b64(&frame), "id": 1 })).await;

    // Recorded, so a later load serves it, but the client retries until acked.
    assert_eq!(h.memory.len("doc-1"), 1);
    assert_eq!(response.status(), Status::Error);
    assert!(response.transmissions.is_empty());
}

#[tokio::test]
async fn answers_sync_step1_from_the_store() {
    let h = Harness::new();
    let (_, update) = edit("stored text");
    h.memory.append("doc-1", &update).await.unwrap();

    let client_step1 =
        Message::Sync(SyncMessage::SyncStep1(Doc::new().transact().state_vector())).encode_v1();
    let response = h.send(json!({ "update": b64(&client_step1) })).await;

    let reply = STANDARD
        .decode(
            messages(&response)[0]["message"]["update"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
    let Message::Sync(SyncMessage::SyncStep2(state)) = Message::decode_v1(&reply).unwrap() else {
        panic!("expected SyncStep2");
    };
    assert_eq!(text_of(&state), "stored text");
    assert!(h.broadcasts().is_empty());
}

#[tokio::test]
async fn relays_awareness_sent_as_a_message_without_storing_it() {
    let h = Harness::new();
    // Awareness frame: type 1, then the length-prefixed awareness update: one
    // entry, for client 42 at clock 0, with the JSON state `null`.
    let update = [1u8, 42, 0, 4, b'n', b'u', b'l', b'l'];
    let mut awareness = vec![1u8, update.len() as u8];
    awareness.extend_from_slice(&update);
    assert_eq!(protocol::classify_message(&awareness), 3);
    let response = h.send(json!({ "update": b64(&awareness), "id": 3 })).await;

    assert_eq!(h.memory.len("doc-1"), 0);
    assert_eq!(h.broadcasts().len(), 1);
    assert!(
        response.transmissions.is_empty(),
        "awareness is never acked"
    );
}

#[tokio::test]
async fn ignores_no_op_and_unreadable_frames() {
    let h = Harness::new();
    let empty_step2 = Message::Sync(SyncMessage::SyncStep2(
        Doc::new()
            .transact()
            .encode_state_as_update_v1(&Default::default()),
    ))
    .encode_v1();
    for data in [
        json!({ "update": b64(&empty_step2), "id": 1 }),
        json!({ "update": "!!not base64!!", "id": 2 }),
        json!({ "update": b64(&[0, 2, 5, 1, 2]), "id": 3 }),
        json!({ "update": b64(&vec![0; 2048]), "id": 4 }), // over the 1 KiB cap
        json!({ "id": 5 }),
    ] {
        let response = h.send(data.clone()).await;
        assert_eq!(response.status(), Status::Success, "{data}");
        assert!(response.transmissions.is_empty(), "{data}");
    }
    assert_eq!(h.memory.len("doc-1"), 0);
    assert!(h.broadcasts().is_empty());
}

#[tokio::test]
async fn rejects_a_message_without_an_authorized_subscription() {
    let h = Harness::new();
    let (frame, _) = edit("sneaky");
    let response = h
        .call(
            "message",
            &h.identifier,
            &json!({ "update": b64(&frame), "id": 1 }).to_string(),
            &[],
        )
        .await;

    assert!(response.stop_streams);
    assert_eq!(messages(&response)[0]["type"], "reject_subscription");
    assert_eq!(h.memory.len("doc-1"), 0);
}

#[tokio::test]
async fn reports_a_causal_gap_at_subscribe() {
    let h = Harness::new();
    // Two edits by one client; store only the second, so it waits on the first.
    let doc = Doc::new();
    let text = doc.get_or_insert_text("t");
    let first = {
        let mut txn = doc.transact_mut();
        text.insert(&mut txn, 0, "a");
        txn.encode_update_v1()
    };
    let second = {
        let mut txn = doc.transact_mut();
        text.insert(&mut txn, 1, "b");
        txn.encode_update_v1()
    };
    h.memory.append("doc-1", &second).await.unwrap();
    h.subscribe(&h.identifier).await;
    assert_eq!(*h.gaps.lock().unwrap(), vec!["doc-1"]);

    // The dependency arrives and the gap heals.
    let frame = Message::Sync(SyncMessage::Update(first)).encode_v1();
    h.send(json!({ "update": b64(&frame), "id": 1 })).await;
    let state = h.memory.load("doc-1").await.unwrap().unwrap();
    assert_eq!(text_of(&state), "ab");
    h.subscribe(&h.identifier).await;
    assert_eq!(h.gaps.lock().unwrap().len(), 1, "no gap once healed");
}
