// The embedded ActionCable server, spoken to over a real WebSocket the way
// @rails/actioncable and @anycable/web speak to it.
use std::sync::Arc;
use std::time::Duration;

use anycable_rpc::Cable;
use axum::extract::ws::WebSocketUpgrade;
use axum::http::{HeaderMap, Uri};
use axum::routing::get;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use futures_util::{SinkExt, StreamExt};
use loco_yrby::LocoLogin;
use loco_yrby::cable::{EmbeddedCable, Hub, HubBroadcaster, PROTOCOL};
use serde_json::{Map, Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use yrby_anycable::{CHANNEL_NAME, DocumentChannel, GrantSigner, MemoryStore};
use yrs::updates::encoder::Encode;
use yrs::{Doc, Text, Transact};

// Loco decodes its login secret as base64.
const LOGIN_SECRET: &str = "bG9naW4tc2VjcmV0LWZvci10ZXN0cw==";
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct Server {
    addr: std::net::SocketAddr,
    hub: Arc<Hub>,
    signer: GrantSigner,
}

async fn server() -> Server {
    let hub = Arc::new(Hub::default());
    let signer = GrantSigner::new("grants");
    let channel = DocumentChannel::new(
        Arc::new(MemoryStore::new()),
        Arc::new(HubBroadcaster(hub.clone())),
        Arc::new(signer.clone()),
    );
    let cable = Cable::new()
        .authenticator(LocoLogin::new(
            Some(LOGIN_SECRET),
            "auth_token",
            "token",
            false,
        ))
        .channel(CHANNEL_NAME, channel);
    let embedded = EmbeddedCable::new(cable, hub.clone());
    let app = axum::Router::new().route(
        "/yrby/cable",
        get(move |ws: WebSocketUpgrade, headers: HeaderMap, uri: Uri| {
            embedded.upgrade(ws, headers, uri)
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Server { addr, hub, signer }
}

fn login(pid: &str) -> String {
    loco_rs::auth::jwt::JWT::new(LOGIN_SECRET)
        .generate_token(60, pid.into(), Map::new())
        .unwrap()
}

async fn connect(server: &Server, query: &str) -> Socket {
    let mut request = format!("ws://{}/yrby/cable{query}", server.addr)
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("sec-websocket-protocol", PROTOCOL.parse().unwrap());
    let (socket, response) = tokio_tungstenite::connect_async(request).await.unwrap();
    assert_eq!(
        response.headers()["sec-websocket-protocol"],
        PROTOCOL,
        "the server accepts ActionCable's subprotocol, or clients hang up"
    );
    socket
}

/// The next frame that is not a ping.
async fn next(socket: &mut Socket) -> Option<Value> {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(5), socket.next())
            .await
            .ok()??
            .ok()?;
        match message {
            Message::Text(text) => {
                let frame: Value = serde_json::from_str(&text).unwrap();
                if frame["type"] != "ping" {
                    return Some(frame);
                }
            }
            Message::Close(_) => return None,
            _ => {}
        }
    }
}

async fn send(socket: &mut Socket, frame: Value) {
    socket
        .send(Message::Text(frame.to_string().into()))
        .await
        .unwrap();
}

fn identifier(grant: &str) -> String {
    json!({ "channel": CHANNEL_NAME, "grant": grant, "name": "body" }).to_string()
}

fn edit(text: &str) -> String {
    let doc = Doc::new();
    let content = doc.get_or_insert_text("content");
    let update = {
        let mut txn = doc.transact_mut();
        content.insert(&mut txn, 0, text);
        txn.encode_update_v1()
    };
    STANDARD.encode(yrs::sync::Message::Sync(yrs::sync::SyncMessage::Update(update)).encode_v1())
}

/// Connect as `pid`, subscribe to `doc`, and read through the confirmation.
async fn subscribed(server: &Server, pid: &str, doc: &str) -> (Socket, String) {
    let mut socket = connect(server, &format!("?token={}", login(pid))).await;
    assert_eq!(next(&mut socket).await.unwrap()["type"], "welcome");
    let id = identifier(&server.signer.sign(doc, "body", 60));
    send(
        &mut socket,
        json!({ "command": "subscribe", "identifier": id }),
    )
    .await;
    let handshake = next(&mut socket).await.unwrap();
    assert!(
        handshake["message"]["update"].is_string(),
        "SyncStep1 first: {handshake}"
    );
    assert_eq!(
        next(&mut socket).await.unwrap()["type"],
        "confirm_subscription"
    );
    (socket, id)
}

#[tokio::test]
async fn refuses_a_connection_without_a_login() {
    let server = server().await;
    let mut socket = connect(&server, "").await;
    let frame = next(&mut socket).await.unwrap();
    assert_eq!(frame["type"], "disconnect");
    assert_eq!(frame["reason"], "unauthorized");
    assert_eq!(frame["reconnect"], false);
    assert_eq!(next(&mut socket).await, None, "and closes");

    let mut socket = connect(&server, "?token=forged").await;
    assert_eq!(next(&mut socket).await.unwrap()["type"], "disconnect");
}

#[tokio::test]
async fn syncs_relays_acks_and_whispers() {
    let server = server().await;
    let (mut ada, id) = subscribed(&server, "ada", "doc-1").await;
    let (mut bob, bob_id) = subscribed(&server, "bob", "doc-1").await;
    assert_eq!(server.hub.subscribers("yrby:doc-1"), 2);

    // A change is relayed to everyone (its sender included), then acked to
    // its sender only.
    let update = edit("hello");
    let data = json!({ "update": update, "id": 7 }).to_string();
    send(
        &mut ada,
        json!({ "command": "message", "identifier": id, "data": data }),
    )
    .await;
    let relayed = next(&mut ada).await.unwrap();
    assert_eq!(relayed["message"]["update"], update);
    assert_eq!(
        next(&mut ada).await.unwrap()["message"],
        json!({ "ack": 7 })
    );
    let received = next(&mut bob).await.unwrap();
    assert_eq!(received["identifier"], bob_id);
    assert_eq!(received["message"]["update"], update);

    // Whispers go to the other subscribers, not back to the sender, and never
    // reach the channel.
    let cursor = json!({ "awareness": "AQI=" });
    send(
        &mut ada,
        json!({ "command": "whisper", "identifier": id, "data": cursor }),
    )
    .await;
    assert_eq!(next(&mut bob).await.unwrap()["message"], cursor);
    let quiet = tokio::time::timeout(Duration::from_millis(300), ada.next()).await;
    assert!(
        quiet.is_err() || matches!(quiet, Ok(Some(Ok(Message::Text(ref t)))) if t.contains("ping")),
        "a whisper does not echo to its sender"
    );

    // Leaving cleans up the streams.
    ada.close(None).await.unwrap();
    bob.close(None).await.unwrap();
    for _ in 0..50 {
        if server.hub.subscribers("yrby:doc-1") == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(server.hub.subscribers("yrby:doc-1"), 0);
}

#[tokio::test]
async fn rejects_a_bad_grant_and_keeps_the_connection() {
    let server = server().await;
    let mut socket = connect(&server, &format!("?token={}", login("ada"))).await;
    assert_eq!(next(&mut socket).await.unwrap()["type"], "welcome");
    let forged = identifier("forged");
    send(
        &mut socket,
        json!({ "command": "subscribe", "identifier": forged }),
    )
    .await;
    let frame = next(&mut socket).await.unwrap();
    assert_eq!(frame["type"], "reject_subscription");
    assert_eq!(frame["identifier"], forged);
    assert_eq!(server.hub.subscribers("yrby:forged"), 0);

    // The connection stays up for other subscriptions.
    let id = identifier(&server.signer.sign("doc-2", "body", 60));
    send(
        &mut socket,
        json!({ "command": "subscribe", "identifier": id }),
    )
    .await;
    assert!(next(&mut socket).await.unwrap()["message"]["update"].is_string());
    assert_eq!(
        next(&mut socket).await.unwrap()["type"],
        "confirm_subscription"
    );
}

#[tokio::test]
async fn pings_every_few_seconds() {
    let server = server().await;
    let mut socket = connect(&server, &format!("?token={}", login("ada"))).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut pinged = false;
    while tokio::time::Instant::now() < deadline {
        if let Ok(Some(Ok(Message::Text(text)))) =
            tokio::time::timeout(Duration::from_secs(5), socket.next()).await
            && serde_json::from_str::<Value>(&text).unwrap()["type"] == "ping"
        {
            pinged = true;
            break;
        }
    }
    assert!(
        pinged,
        "clients treat about six silent seconds as a dead connection"
    );
}
