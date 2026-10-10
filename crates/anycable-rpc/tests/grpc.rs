// The service over a real gRPC connection, called the way anycable-go calls it.
use anycable_rpc::proto::rpc_client::RpcClient;
use anycable_rpc::proto::{CommandMessage, ConnectionRequest, Env, Status};
use anycable_rpc::{Cable, Channel, ChannelContext, ChannelError, Reply, async_trait};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_stream::wrappers::TcpListenerStream;

struct Echo;

#[async_trait]
impl Channel for Echo {
    async fn subscribed(
        &self,
        ctx: &ChannelContext,
        reply: &mut Reply,
    ) -> Result<(), ChannelError> {
        reply.stream_from("echo");
        reply.transmit(json!({ "sid": ctx.meta.sid() }));
        Ok(())
    }
}

async fn client() -> RpcClient<tonic::transport::Channel> {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let cable = Cable::new().channel("EchoChannel", Echo);
    tokio::spawn(
        tonic::transport::Server::builder()
            .add_service(anycable_rpc::service(cable))
            .serve_with_incoming(TcpListenerStream::new(listener)),
    );
    let channel = tonic::transport::Endpoint::from_shared(format!("http://{addr}"))
        .unwrap()
        .connect()
        .await
        .unwrap();
    RpcClient::new(channel)
}

fn with_sid<T>(message: T) -> tonic::Request<T> {
    let mut request = tonic::Request::new(message);
    request
        .metadata_mut()
        .insert("sid", "sid-42".parse().unwrap());
    request
        .metadata_mut()
        .insert("protov", "v1".parse().unwrap());
    request
}

#[tokio::test]
async fn connects_and_subscribes_over_grpc() {
    let mut client = client().await;

    let connected = client
        .connect(with_sid(ConnectionRequest {
            env: Some(Env {
                url: "ws://x/cable".into(),
                ..Default::default()
            }),
        }))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(connected.status(), Status::Success);
    assert_eq!(
        connected.transmissions,
        vec![r#"{"sid":"sid-42","type":"welcome"}"#]
    );

    let identifier = json!({ "channel": "EchoChannel" }).to_string();
    let subscribed = client
        .command(with_sid(CommandMessage {
            command: "subscribe".into(),
            identifier: identifier.clone(),
            connection_identifiers: connected.identifiers,
            ..Default::default()
        }))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(subscribed.status(), Status::Success);
    assert_eq!(subscribed.streams, vec!["echo"]);
    let frames: Vec<Value> = subscribed
        .transmissions
        .iter()
        .map(|t| serde_json::from_str(t).unwrap())
        .collect();
    assert_eq!(
        frames[0],
        json!({ "identifier": identifier, "message": { "sid": "sid-42" } })
    );
    assert_eq!(frames[1]["type"], "confirm_subscription");
}
