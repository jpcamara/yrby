//! An ActionCable server inside the Loco app, so it needs no anycable-go.
//!
//! It speaks ActionCable's WebSocket protocol (`actioncable-v1-json`), so the
//! clients made for it (`@rails/actioncable`, `@anycable/web`) connect to the
//! app directly. Each command runs through the same [`Cable`] that serves
//! anycable-go's RPC calls, and its reply is applied the way anycable-go
//! applies it: streams first, then subscription state, then the messages for
//! this client, in order. So a change is still stored, then relayed, then
//! acknowledged.
//!
//! Streams live in this process's memory, so every client of a document must
//! connect to the same process. Use the AnyCable transport to run several.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anycable_rpc::proto::{CommandMessage, ConnectionRequest, DisconnectRequest, Env, Status};
use anycable_rpc::{BroadcastError, Broadcaster, Cable, RpcHandler, RpcMeta, WHISPER_STREAM_STATE};
use async_trait::async_trait;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, Uri};
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;

/// The subprotocol ActionCable clients ask for.
pub const PROTOCOL: &str = "actioncable-v1-json";
const PING_INTERVAL: Duration = Duration::from_secs(3);

type Outbox = mpsc::UnboundedSender<String>;

struct Subscriber {
    connection: u64,
    identifier: String,
    outbox: Outbox,
}

/// The streams of this process: who is subscribed to what.
#[derive(Default)]
pub struct Hub {
    streams: Mutex<HashMap<String, Vec<Subscriber>>>,
}

impl Hub {
    fn subscribe(&self, stream: &str, connection: u64, identifier: &str, outbox: &Outbox) {
        let mut streams = self.streams.lock().unwrap();
        let subscribers = streams.entry(stream.to_string()).or_default();
        if !subscribers
            .iter()
            .any(|s| s.connection == connection && s.identifier == identifier)
        {
            subscribers.push(Subscriber {
                connection,
                identifier: identifier.to_string(),
                outbox: outbox.clone(),
            });
        }
    }

    fn unsubscribe(&self, keep: impl Fn(&str, &Subscriber) -> bool) {
        let mut streams = self.streams.lock().unwrap();
        for (stream, subscribers) in streams.iter_mut() {
            subscribers.retain(|s| keep(stream, s));
        }
        streams.retain(|_, subscribers| !subscribers.is_empty());
    }

    /// Deliver `data` (usually JSON) to every subscriber of `stream`, except
    /// the connection `except`, wrapped as ActionCable delivers broadcasts.
    pub fn publish(&self, stream: &str, data: &str, except: Option<u64>) {
        let message = serde_json::from_str::<Value>(data).unwrap_or_else(|_| Value::from(data));
        let streams = self.streams.lock().unwrap();
        for subscriber in streams.get(stream).into_iter().flatten() {
            if Some(subscriber.connection) == except {
                continue;
            }
            let frame = json!({ "identifier": subscriber.identifier, "message": message });
            // A closed connection's outbox is gone; it unsubscribes as it ends.
            let _ = subscriber.outbox.send(frame.to_string());
        }
    }

    /// How many connections are subscribed to `stream`.
    pub fn subscribers(&self, stream: &str) -> usize {
        self.streams.lock().unwrap().get(stream).map_or(0, Vec::len)
    }
}

/// Publishes to the [`Hub`]: the broadcaster for channels served in process.
pub struct HubBroadcaster(pub Arc<Hub>);

#[async_trait]
impl Broadcaster for HubBroadcaster {
    async fn broadcast(&self, stream: &str, data: String) -> Result<(), BroadcastError> {
        self.0.publish(stream, &data, None);
        Ok(())
    }
}

/// The WebSocket endpoint: a [`Cable`] and the [`Hub`] its channels stream on.
#[derive(Clone)]
pub struct EmbeddedCable {
    cable: Arc<Cable>,
    hub: Arc<Hub>,
    next_connection: Arc<AtomicU64>,
}

impl EmbeddedCable {
    pub fn new(cable: Cable, hub: Arc<Hub>) -> Self {
        Self {
            cable: Arc::new(cable),
            hub,
            next_connection: Arc::new(AtomicU64::new(1)),
        }
    }

    /// The Axum handler for the cable route.
    pub async fn upgrade(self, ws: WebSocketUpgrade, headers: HeaderMap, uri: Uri) -> Response {
        // Only the cookie reaches the cable's authenticator, as anycable-go
        // forwards only cookies by default.
        let env = Env {
            url: uri.to_string(),
            headers: headers
                .get("cookie")
                .and_then(|v| v.to_str().ok())
                .map(|cookie| HashMap::from([("cookie".to_string(), cookie.to_string())]))
                .unwrap_or_default(),
            ..Default::default()
        };
        ws.protocols([PROTOCOL])
            .on_upgrade(move |socket| async move { self.serve(socket, env).await })
    }

    async fn serve(self, socket: WebSocket, env: Env) {
        let connection = self.next_connection.fetch_add(1, Ordering::Relaxed);
        let meta = RpcMeta::new(HashMap::from([("sid".to_string(), connection.to_string())]));
        let (mut sink, mut incoming) = socket.split();
        let (outbox, mut outgoing) = mpsc::unbounded_channel::<String>();
        let writer = tokio::spawn(async move {
            while let Some(frame) = outgoing.recv().await {
                if sink.send(Message::Text(frame.into())).await.is_err() {
                    break;
                }
            }
            let _ = sink.close().await;
        });

        let connected = self
            .cable
            .connect(
                &meta,
                ConnectionRequest {
                    env: Some(env.clone()),
                },
            )
            .await;
        let accepted = connected.status() == Status::Success;
        for frame in connected.transmissions {
            let _ = outbox.send(frame);
        }
        if !accepted {
            drop(outbox);
            let _ = writer.await;
            return;
        }
        let identifiers = connected.identifiers;

        let pinger = {
            let outbox = outbox.clone();
            tokio::spawn(async move {
                let mut tick = tokio::time::interval(PING_INTERVAL);
                tick.tick().await;
                loop {
                    tick.tick().await;
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_or(0, |d| d.as_secs());
                    if outbox
                        .send(json!({ "type": "ping", "message": now }).to_string())
                        .is_err()
                    {
                        break;
                    }
                }
            })
        };

        // Each subscription's state, as anycable-go keeps it.
        let mut states: HashMap<String, HashMap<String, String>> = HashMap::new();
        while let Some(Ok(message)) = incoming.next().await {
            let Message::Text(text) = message else {
                if matches!(message, Message::Close(_)) {
                    break;
                }
                continue;
            };
            let Ok(Value::Object(command)) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            let name = command
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let Some(identifier) = command.get("identifier").and_then(Value::as_str) else {
                continue;
            };

            if name == "whisper" {
                // Relayed to the whisper stream's other subscribers, never to
                // the backend, as anycable-go does.
                if let Some(stream) = states
                    .get(identifier)
                    .and_then(|s| s.get(WHISPER_STREAM_STATE))
                    && let Some(data) = command.get("data")
                {
                    self.hub
                        .publish(stream, &data.to_string(), Some(connection));
                }
                continue;
            }
            if name == "subscribe" && states.contains_key(identifier) {
                continue;
            }
            if !matches!(name, "subscribe" | "unsubscribe" | "message") {
                continue;
            }

            let data = match command.get("data") {
                Some(Value::String(data)) => data.clone(),
                Some(other) => other.to_string(),
                None => String::new(),
            };
            let request = CommandMessage {
                command: name.to_string(),
                identifier: identifier.to_string(),
                connection_identifiers: identifiers.clone(),
                data,
                env: Some(Env {
                    istate: states.get(identifier).cloned().unwrap_or_default(),
                    ..env.clone()
                }),
            };
            let reply = self.cable.command(&meta, request).await;

            if reply.stop_streams {
                self.hub.unsubscribe(|_, s| {
                    !(s.connection == connection && s.identifier == identifier)
                });
            }
            for stream in &reply.stopped_streams {
                self.hub.unsubscribe(|name, s| {
                    !(name == stream && s.connection == connection && s.identifier == identifier)
                });
            }
            for stream in &reply.streams {
                self.hub.subscribe(stream, connection, identifier, &outbox);
            }
            let confirmed = name == "subscribe" && reply.status() == Status::Success;
            let rejected = reply
                .transmissions
                .iter()
                .any(|t| t.contains("\"reject_subscription\""));
            if confirmed {
                states.insert(identifier.to_string(), HashMap::new());
            }
            if let Some(env) = &reply.env
                && let Some(state) = states.get_mut(identifier)
            {
                state.extend(env.istate.clone());
            }
            if name == "unsubscribe" || rejected {
                states.remove(identifier);
            }
            for frame in reply.transmissions {
                let _ = outbox.send(frame);
            }
            if reply.disconnect {
                break;
            }
        }

        pinger.abort();
        self.hub.unsubscribe(|_, s| s.connection != connection);
        let subscriptions: Vec<String> = states.keys().cloned().collect();
        let istate = states
            .iter()
            .map(|(id, state)| (id.clone(), serde_json::to_string(state).unwrap_or_default()))
            .collect();
        self.cable
            .disconnect(
                &meta,
                DisconnectRequest {
                    identifiers,
                    subscriptions,
                    env: Some(Env { istate, ..env }),
                },
            )
            .await;
        drop(outbox);
        let _ = writer.await;
    }
}
