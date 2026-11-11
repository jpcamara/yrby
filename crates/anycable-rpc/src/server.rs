//! anycable-go's gRPC RPC service.
//!
//! anycable-go calls the backend over gRPC by default (`--rpc_host`, default
//! `localhost:50051`). [`service`] turns an [`RpcHandler`] into a tonic
//! service to add to a `tonic::transport::Server`.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tonic::{Request, Response};

use crate::proto::rpc_server::{Rpc, RpcServer};
use crate::proto::{
    CommandMessage, CommandResponse, ConnectionRequest, ConnectionResponse, DisconnectRequest,
    DisconnectResponse,
};

/// Call metadata anycable-go attaches to every RPC: `sid` (its id for the
/// WebSocket) and `protov` (the RPC protocol version).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RpcMeta {
    values: HashMap<String, String>,
}

impl RpcMeta {
    pub fn new(values: HashMap<String, String>) -> Self {
        Self { values }
    }

    fn from_metadata(metadata: &tonic::metadata::MetadataMap) -> Self {
        let values = metadata
            .iter()
            .filter_map(|entry| match entry {
                tonic::metadata::KeyAndValueRef::Ascii(key, value) => {
                    Some((key.as_str().to_string(), value.to_str().ok()?.to_string()))
                }
                tonic::metadata::KeyAndValueRef::Binary(..) => None,
            })
            .collect();
        Self { values }
    }

    /// The session id anycable-go assigned this WebSocket.
    pub fn sid(&self) -> Option<&str> {
        self.get("sid")
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }
}

/// A backend for anycable-go. Report refusals and failures through the
/// response's `status`; a handler never fails the RPC itself.
///
/// Most applications implement [`crate::Channel`]s and serve a
/// [`crate::Cable`] instead of implementing this directly.
#[async_trait]
pub trait RpcHandler: Send + Sync + 'static {
    async fn connect(&self, meta: &RpcMeta, request: ConnectionRequest) -> ConnectionResponse;
    async fn command(&self, meta: &RpcMeta, request: CommandMessage) -> CommandResponse;
    async fn disconnect(&self, meta: &RpcMeta, request: DisconnectRequest) -> DisconnectResponse;
}

/// The gRPC service, ready for `tonic::transport::Server::add_service`.
///
/// ```no_run
/// # async fn run() -> Result<(), Box<dyn std::error::Error>> {
/// let cable = anycable_rpc::Cable::new();
/// tonic::transport::Server::builder()
///     .add_service(anycable_rpc::service(cable))
///     .serve("127.0.0.1:50051".parse()?)
///     .await?;
/// # Ok(()) }
/// ```
///
/// gRPC has no authentication of its own here, as with AnyCable's Ruby RPC
/// server: listen on a private address that only anycable-go can reach.
pub fn service(handler: impl RpcHandler) -> RpcServer<Service> {
    RpcServer::new(Service {
        handler: Arc::new(handler),
    })
}

/// The tonic service behind [`service`].
pub struct Service {
    handler: Arc<dyn RpcHandler>,
}

#[tonic::async_trait]
impl Rpc for Service {
    async fn connect(
        &self,
        request: Request<ConnectionRequest>,
    ) -> Result<Response<ConnectionResponse>, tonic::Status> {
        let meta = RpcMeta::from_metadata(request.metadata());
        Ok(Response::new(
            self.handler.connect(&meta, request.into_inner()).await,
        ))
    }

    async fn command(
        &self,
        request: Request<CommandMessage>,
    ) -> Result<Response<CommandResponse>, tonic::Status> {
        let meta = RpcMeta::from_metadata(request.metadata());
        Ok(Response::new(
            self.handler.command(&meta, request.into_inner()).await,
        ))
    }

    async fn disconnect(
        &self,
        request: Request<DisconnectRequest>,
    ) -> Result<Response<DisconnectResponse>, tonic::Status> {
        let meta = RpcMeta::from_metadata(request.metadata());
        Ok(Response::new(
            self.handler.disconnect(&meta, request.into_inner()).await,
        ))
    }
}
