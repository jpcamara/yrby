//! ActionCable-style channels on top of the raw RPC calls.
//!
//! A [`Cable`] answers anycable-go the way an ActionCable server would: it
//! sends the `welcome`, routes each command to the [`Channel`] named in its
//! identifier, and wraps what the channel does into `confirm_subscription`,
//! `reject_subscription`, and `{identifier, message}` frames. Clients written
//! for ActionCable (`@rails/actioncable`, `@anycable/web`) work unchanged.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::proto::{
    CommandMessage, CommandResponse, ConnectionRequest, ConnectionResponse, DisconnectRequest,
    DisconnectResponse, Env, EnvResponse, Status,
};
use crate::server::{RpcHandler, RpcMeta};

/// The channel-state key anycable-go reads to route a client's `whisper`:
/// whispers go to the stream named here, and to no stream if it is unset.
pub const WHISPER_STREAM_STATE: &str = "$w";

pub type ChannelError = Box<dyn std::error::Error + Send + Sync>;

/// Accepts or refuses a new connection, the way an ActionCable
/// `Connection#connect` does.
#[async_trait]
pub trait Authenticator: Send + Sync + 'static {
    /// Return the connection identifiers (a JSON object, such as
    /// `{"user_id": 42}`) to accept, or `None` to refuse. The identifiers come
    /// back with every command as [`ChannelContext::connection_identifiers`].
    async fn connect(&self, meta: &RpcMeta, env: &Env) -> Option<Value>;
}

/// Accepts every connection with no identifiers. Channels still decide who
/// may subscribe to what.
pub struct AllowAll;

#[async_trait]
impl Authenticator for AllowAll {
    async fn connect(&self, _: &RpcMeta, _: &Env) -> Option<Value> {
        Some(json!({}))
    }
}

/// One channel class, in ActionCable terms. anycable-go keeps no channel
/// instance between calls: anything a later call needs goes in
/// [`Reply::set_state`] and comes back in [`ChannelContext::state`].
#[async_trait]
pub trait Channel: Send + Sync + 'static {
    /// A client subscribed. Stream, transmit, or [`Reply::reject`].
    async fn subscribed(&self, ctx: &ChannelContext, reply: &mut Reply)
    -> Result<(), ChannelError>;

    /// A client sent a message: `subscription.send(data)` or `perform`. The
    /// ActionCable action, when there is one, is in `data["action"]`.
    async fn receive(
        &self,
        _ctx: &ChannelContext,
        _data: Value,
        _reply: &mut Reply,
    ) -> Result<(), ChannelError> {
        Ok(())
    }

    /// The client unsubscribed or disconnected. Streams stop on their own.
    async fn unsubscribed(&self, _ctx: &ChannelContext) -> Result<(), ChannelError> {
        Ok(())
    }
}

/// What a channel knows about the call it is handling.
#[derive(Debug, Clone)]
pub struct ChannelContext {
    /// The raw identifier, exactly as the client sent it.
    pub identifier: String,
    /// The `channel` field of the identifier.
    pub channel: String,
    /// The rest of the identifier: ActionCable's `params`.
    pub params: Map<String, Value>,
    /// What the [`Authenticator`] returned for this connection.
    pub connection_identifiers: Value,
    /// This subscription's state, as set by earlier [`Reply::set_state`] calls.
    /// anycable-go holds it server side, so a client cannot forge it.
    pub state: HashMap<String, String>,
    pub env: Env,
    pub meta: RpcMeta,
}

impl ChannelContext {
    /// A string parameter from the identifier.
    pub fn param(&self, name: &str) -> Option<&str> {
        self.params.get(name).and_then(Value::as_str)
    }

    pub fn state(&self, key: &str) -> Option<&str> {
        self.state.get(key).map(String::as_str)
    }
}

/// What a channel does in response to one call. anycable-go applies it after
/// the call returns: subscribes and unsubscribes streams, stores state, and
/// sends the transmissions to this client in order.
#[derive(Debug)]
pub struct Reply {
    identifier: String,
    transmissions: Vec<String>,
    streams: Vec<String>,
    stopped_streams: Vec<String>,
    stop_all_streams: bool,
    state: HashMap<String, String>,
    rejected: bool,
    disconnect: bool,
}

impl Reply {
    fn new(identifier: &str) -> Self {
        Self {
            identifier: identifier.to_string(),
            transmissions: Vec::new(),
            streams: Vec::new(),
            stopped_streams: Vec::new(),
            stop_all_streams: false,
            state: HashMap::new(),
            rejected: false,
            disconnect: false,
        }
    }

    /// Send `message` to this client only, as ActionCable's `transmit` does.
    pub fn transmit(&mut self, message: impl Serialize) {
        let frame = json!({ "identifier": self.identifier, "message": message });
        self.transmissions.push(frame.to_string());
    }

    /// Deliver broadcasts on `stream` to this subscription.
    pub fn stream_from(&mut self, stream: impl Into<String>) {
        self.streams.push(stream.into());
    }

    /// Like [`Reply::stream_from`], and also route this client's whispers to
    /// `stream`. anycable-go relays whispers to the stream's other subscribers
    /// without calling the backend. A subscription whispers to one stream at most.
    pub fn stream_from_with_whisper(&mut self, stream: impl Into<String>) {
        let stream = stream.into();
        self.state
            .insert(WHISPER_STREAM_STATE.to_string(), stream.clone());
        self.streams.push(stream);
    }

    pub fn stop_stream_from(&mut self, stream: impl Into<String>) {
        self.stopped_streams.push(stream.into());
    }

    pub fn stop_all_streams(&mut self) {
        self.stop_all_streams = true;
    }

    /// Keep `value` for later calls on this subscription.
    pub fn set_state(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.state.insert(key.into(), value.into());
    }

    /// Refuse the subscription. During `subscribed` the client gets
    /// `reject_subscription` instead of a confirmation. Later, the
    /// subscription's streams stop and the client is told it was rejected, as
    /// ActionCable's `reject_subscription` does.
    pub fn reject(&mut self) {
        self.rejected = true;
    }

    pub fn is_rejected(&self) -> bool {
        self.rejected
    }

    /// Close the client's whole connection after this reply.
    pub fn disconnect(&mut self) {
        self.disconnect = true;
    }

    fn type_frame(&self, kind: &str) -> String {
        json!({ "identifier": self.identifier, "type": kind }).to_string()
    }

    fn into_response(mut self, status: Status) -> CommandResponse {
        if self.rejected {
            self.stop_all_streams = true;
            self.streams.clear();
            self.transmissions
                .push(self.type_frame("reject_subscription"));
        }
        let env = (!self.state.is_empty()).then(|| EnvResponse {
            istate: self.state,
            ..Default::default()
        });
        CommandResponse {
            status: status as i32,
            disconnect: self.disconnect,
            stop_streams: self.stop_all_streams,
            streams: self.streams,
            transmissions: self.transmissions,
            env,
            stopped_streams: self.stopped_streams,
            ..Default::default()
        }
    }
}

/// An ActionCable-compatible backend: channels by name, plus a connection
/// [`Authenticator`]. Serve it with [`crate::service`].
pub struct Cable {
    authenticator: Arc<dyn Authenticator>,
    channels: HashMap<String, Arc<dyn Channel>>,
}

impl Default for Cable {
    fn default() -> Self {
        Self::new()
    }
}

impl Cable {
    /// A cable that accepts every connection ([`AllowAll`]).
    pub fn new() -> Self {
        Self {
            authenticator: Arc::new(AllowAll),
            channels: HashMap::new(),
        }
    }

    pub fn authenticator(mut self, authenticator: impl Authenticator) -> Self {
        self.authenticator = Arc::new(authenticator);
        self
    }

    /// Serve `channel` to identifiers whose `channel` field is `name`.
    pub fn channel(mut self, name: impl Into<String>, channel: impl Channel) -> Self {
        self.channels.insert(name.into(), Arc::new(channel));
        self
    }

    fn context(
        &self,
        identifier: &str,
        connection_identifiers: &str,
        state: HashMap<String, String>,
        env: Env,
        meta: &RpcMeta,
    ) -> Option<(ChannelContext, Arc<dyn Channel>)> {
        let Ok(Value::Object(mut params)) = serde_json::from_str::<Value>(identifier) else {
            return None;
        };
        let channel = match params.remove("channel") {
            Some(Value::String(name)) => name,
            _ => return None,
        };
        let handler = self.channels.get(&channel)?.clone();
        let ctx = ChannelContext {
            identifier: identifier.to_string(),
            channel,
            params,
            connection_identifiers: serde_json::from_str(connection_identifiers)
                .unwrap_or(Value::Null),
            state,
            env,
            meta: meta.clone(),
        };
        Some((ctx, handler))
    }
}

fn failed(error: impl std::fmt::Display) -> CommandResponse {
    CommandResponse {
        status: Status::Error as i32,
        error_msg: error.to_string(),
        ..Default::default()
    }
}

#[async_trait]
impl RpcHandler for Cable {
    async fn connect(&self, meta: &RpcMeta, request: ConnectionRequest) -> ConnectionResponse {
        match self
            .authenticator
            .connect(meta, &request.env.unwrap_or_default())
            .await
        {
            Some(identifiers) => {
                let welcome = match meta.sid() {
                    Some(sid) => json!({ "type": "welcome", "sid": sid }),
                    None => json!({ "type": "welcome" }),
                };
                ConnectionResponse {
                    status: Status::Success as i32,
                    identifiers: identifiers.to_string(),
                    transmissions: vec![welcome.to_string()],
                    ..Default::default()
                }
            }
            // What ActionCable's reject_unauthorized_connection sends.
            None => ConnectionResponse {
                status: Status::Failure as i32,
                transmissions: vec![
                    json!({ "type": "disconnect", "reason": "unauthorized", "reconnect": false })
                        .to_string(),
                ],
                ..Default::default()
            },
        }
    }

    async fn command(&self, meta: &RpcMeta, request: CommandMessage) -> CommandResponse {
        let CommandMessage {
            command,
            identifier,
            connection_identifiers,
            data,
            env,
        } = request;
        let env = env.unwrap_or_default();
        let state = env.istate.clone();
        let Some((ctx, channel)) =
            self.context(&identifier, &connection_identifiers, state, env, meta)
        else {
            // An unknown channel is refused rather than left hanging.
            let mut reply = Reply::new(&identifier);
            reply.reject();
            tracing::warn!(identifier = %identifier, "no channel for identifier");
            return reply.into_response(Status::Failure);
        };
        let mut reply = Reply::new(&identifier);
        match command.as_str() {
            "subscribe" => {
                if let Err(error) = channel.subscribed(&ctx, &mut reply).await {
                    tracing::error!(channel = %ctx.channel, %error, "subscribed failed");
                    reply.reject();
                    let mut response = reply.into_response(Status::Error);
                    response.error_msg = error.to_string();
                    return response;
                }
                if reply.rejected {
                    return reply.into_response(Status::Failure);
                }
                // Transmissions from `subscribed` go first, as in ActionCable.
                let confirm = reply.type_frame("confirm_subscription");
                reply.transmissions.push(confirm);
                reply.into_response(Status::Success)
            }
            "message" => {
                let data = match serde_json::from_str(&data) {
                    Ok(data) => data,
                    Err(error) => return failed(format!("message data is not JSON: {error}")),
                };
                match channel.receive(&ctx, data, &mut reply).await {
                    Ok(()) => reply.into_response(Status::Success),
                    Err(error) => {
                        tracing::error!(channel = %ctx.channel, %error, "receive failed");
                        failed(error)
                    }
                }
            }
            "unsubscribe" => {
                if let Err(error) = channel.unsubscribed(&ctx).await {
                    tracing::error!(channel = %ctx.channel, %error, "unsubscribed failed");
                }
                reply.stop_all_streams();
                reply.into_response(Status::Success)
            }
            other => failed(format!("unknown command {other:?}")),
        }
    }

    async fn disconnect(&self, meta: &RpcMeta, request: DisconnectRequest) -> DisconnectResponse {
        // A disconnect carries every subscription's state, JSON-encoded under
        // its identifier.
        let request_env = request.env.unwrap_or_default();
        for identifier in &request.subscriptions {
            let state = request_env
                .istate
                .get(identifier)
                .and_then(|encoded| serde_json::from_str(encoded).ok())
                .unwrap_or_default();
            let env = Env {
                istate: HashMap::new(),
                ..request_env.clone()
            };
            if let Some((ctx, channel)) =
                self.context(identifier, &request.identifiers, state, env, meta)
                && let Err(error) = channel.unsubscribed(&ctx).await
            {
                tracing::error!(channel = %ctx.channel, %error, "unsubscribed failed");
            }
        }
        DisconnectResponse {
            status: Status::Success as i32,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct Room {
        unsubscribed: Arc<Mutex<Vec<HashMap<String, String>>>>,
    }

    #[async_trait]
    impl Channel for Room {
        async fn subscribed(
            &self,
            ctx: &ChannelContext,
            reply: &mut Reply,
        ) -> Result<(), ChannelError> {
            match ctx.param("room") {
                Some("secret") => reply.reject(),
                Some("boom") => return Err("database down".into()),
                Some(room) => {
                    reply.stream_from(format!("room:{room}"));
                    reply.stream_from_with_whisper(format!("room:{room}:typing"));
                    reply.set_state("room", room);
                    reply.transmit(json!({ "hello": room }));
                }
                None => reply.reject(),
            }
            Ok(())
        }

        async fn receive(
            &self,
            ctx: &ChannelContext,
            data: Value,
            reply: &mut Reply,
        ) -> Result<(), ChannelError> {
            match ctx.state("room") {
                Some(room) => reply.transmit(json!({ "room": room, "echo": data })),
                None => reply.reject(),
            }
            Ok(())
        }

        async fn unsubscribed(&self, ctx: &ChannelContext) -> Result<(), ChannelError> {
            self.unsubscribed.lock().unwrap().push(ctx.state.clone());
            Ok(())
        }
    }

    fn command(
        command: &str,
        identifier: Value,
        data: &str,
        istate: &[(&str, &str)],
    ) -> CommandMessage {
        CommandMessage {
            command: command.into(),
            identifier: identifier.to_string(),
            connection_identifiers: "{}".into(),
            data: data.into(),
            env: Some(Env {
                istate: istate
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
                ..Default::default()
            }),
        }
    }

    fn frames(response: &CommandResponse) -> Vec<Value> {
        response
            .transmissions
            .iter()
            .map(|t| serde_json::from_str(t).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn welcomes_with_the_session_id() {
        let meta = RpcMeta::new([("sid".to_string(), "abc".to_string())].into());
        let response = Cable::new()
            .connect(&meta, ConnectionRequest::default())
            .await;
        assert_eq!(response.status(), Status::Success);
        assert_eq!(response.identifiers, "{}");
        assert_eq!(
            response.transmissions,
            vec![r#"{"sid":"abc","type":"welcome"}"#]
        );
    }

    #[tokio::test]
    async fn refuses_connections_the_authenticator_refuses() {
        struct Nobody;
        #[async_trait]
        impl Authenticator for Nobody {
            async fn connect(&self, _: &RpcMeta, _: &Env) -> Option<Value> {
                None
            }
        }
        let response = Cable::new()
            .authenticator(Nobody)
            .connect(&RpcMeta::default(), ConnectionRequest::default())
            .await;
        assert_eq!(response.status(), Status::Failure);
        assert!(response.transmissions[0].contains("unauthorized"));
    }

    #[tokio::test]
    async fn subscribes_transmits_then_confirms() {
        let cable = Cable::new().channel("RoomChannel", Room::default());
        let id = json!({ "channel": "RoomChannel", "room": "lobby" });
        let response = cable
            .command(
                &RpcMeta::default(),
                command("subscribe", id.clone(), "", &[]),
            )
            .await;

        assert_eq!(response.status(), Status::Success);
        assert_eq!(response.streams, vec!["room:lobby", "room:lobby:typing"]);
        let istate = &response.env.as_ref().unwrap().istate;
        assert_eq!(istate["room"], "lobby");
        assert_eq!(istate[WHISPER_STREAM_STATE], "room:lobby:typing");
        let frames = frames(&response);
        assert_eq!(
            frames[0],
            json!({ "identifier": id.to_string(), "message": { "hello": "lobby" } })
        );
        assert_eq!(
            frames[1],
            json!({ "identifier": id.to_string(), "type": "confirm_subscription" })
        );
    }

    #[tokio::test]
    async fn rejects_without_streams() {
        let cable = Cable::new().channel("RoomChannel", Room::default());
        let id = json!({ "channel": "RoomChannel", "room": "secret" });
        let response = cable
            .command(&RpcMeta::default(), command("subscribe", id, "", &[]))
            .await;
        assert_eq!(response.status(), Status::Failure);
        assert!(response.streams.is_empty());
        assert!(response.stop_streams);
        assert_eq!(frames(&response)[0]["type"], "reject_subscription");
    }

    #[tokio::test]
    async fn a_failing_subscribe_is_an_error_and_a_rejection() {
        let cable = Cable::new().channel("RoomChannel", Room::default());
        let id = json!({ "channel": "RoomChannel", "room": "boom" });
        let response = cable
            .command(&RpcMeta::default(), command("subscribe", id, "", &[]))
            .await;
        assert_eq!(response.status(), Status::Error);
        assert_eq!(response.error_msg, "database down");
        assert_eq!(frames(&response)[0]["type"], "reject_subscription");
    }

    #[tokio::test]
    async fn rejects_an_unknown_channel() {
        let cable = Cable::new();
        let id = json!({ "channel": "Nope" });
        let response = cable
            .command(&RpcMeta::default(), command("subscribe", id, "", &[]))
            .await;
        assert_eq!(response.status(), Status::Failure);
        assert_eq!(frames(&response)[0]["type"], "reject_subscription");
    }

    #[tokio::test]
    async fn messages_see_the_subscription_state() {
        let cable = Cable::new().channel("RoomChannel", Room::default());
        let id = json!({ "channel": "RoomChannel", "room": "lobby" });
        let response = cable
            .command(
                &RpcMeta::default(),
                command(
                    "message",
                    id.clone(),
                    r#"{"text":"hi"}"#,
                    &[("room", "lobby")],
                ),
            )
            .await;
        assert_eq!(response.status(), Status::Success);
        assert_eq!(
            frames(&response)[0]["message"],
            json!({ "room": "lobby", "echo": { "text": "hi" } })
        );

        // Without the state set at subscribe, the channel rejects mid-subscription.
        let response = cable
            .command(&RpcMeta::default(), command("message", id, "{}", &[]))
            .await;
        assert!(response.stop_streams);
        assert_eq!(frames(&response)[0]["type"], "reject_subscription");
    }

    #[tokio::test]
    async fn a_message_that_is_not_json_is_an_error() {
        let cable = Cable::new().channel("RoomChannel", Room::default());
        let id = json!({ "channel": "RoomChannel", "room": "lobby" });
        let response = cable
            .command(&RpcMeta::default(), command("message", id, "{", &[]))
            .await;
        assert_eq!(response.status(), Status::Error);
    }

    #[tokio::test]
    async fn disconnect_unsubscribes_each_channel_with_its_state() {
        let room = Room::default();
        let seen = room.unsubscribed.clone();
        let cable = Cable::new().channel("RoomChannel", room);
        let id = json!({ "channel": "RoomChannel", "room": "lobby" }).to_string();
        let request = DisconnectRequest {
            identifiers: "{}".into(),
            subscriptions: vec![id.clone()],
            env: Some(Env {
                istate: [(id, r#"{"room":"lobby"}"#.to_string())].into(),
                ..Default::default()
            }),
        };
        let response = cable.disconnect(&RpcMeta::default(), request).await;
        assert_eq!(response.status(), Status::Success);
        assert_eq!(seen.lock().unwrap()[0]["room"], "lobby");
    }
}
