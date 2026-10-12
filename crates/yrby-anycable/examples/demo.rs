// A demo backend (cargo run --example demo): the yrby document channel served to anycable-go over gRPC,
// with an in-memory store. Run anycable-go next to it:
//
//   anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http
//
// It also serves a small HTTP API for demos and end-to-end tests. Nothing in
// that API is safe to expose: it mints grants for any document on request.
//
//   GET  /grant?doc=KEY&name=NAME&ttl=SECONDS  -> {"grant": "..."}
//   GET  /documents/KEY                        -> {"state": base64|null, "updates": n}
//   POST /documents/KEY/faults?delay_ms=&fail_appends=
//   GET  /stats                                -> {"awareness_via_rpc": n}
//
// Environment: YRBY_RPC_ADDR (127.0.0.1:50051), YRBY_HTTP_ADDR
// (127.0.0.1:3100), ANYCABLE_BROADCAST_URL
// (http://127.0.0.1:8090/_broadcast), ANYCABLE_BROADCAST_KEY, and
// YRBY_GRANT_SECRET.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anycable_rpc::{BroadcastError, Broadcaster, Cable, HttpBroadcaster, async_trait};
use axum::extract::{Path, Query, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use yrby_anycable::{
    CHANNEL_NAME, DocumentChannel, DocumentStore, GrantSigner, MemoryStore, StoreError,
};

#[derive(Default, Clone, Copy)]
struct Faults {
    delay_ms: u64,
    fail_appends: usize,
}

/// The in-memory store, with faults a test can switch on per document.
#[derive(Default)]
struct DemoStore {
    inner: MemoryStore,
    faults: Mutex<HashMap<String, Faults>>,
}

#[async_trait]
impl DocumentStore for DemoStore {
    async fn load(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError> {
        self.inner.load(key).await
    }

    async fn append(&self, key: &str, update: &[u8]) -> Result<(), StoreError> {
        let faults = self
            .faults
            .lock()
            .unwrap()
            .get(key)
            .copied()
            .unwrap_or_default();
        if faults.delay_ms > 0 {
            tokio::time::sleep(Duration::from_millis(faults.delay_ms)).await;
        }
        if faults.fail_appends > 0 {
            if let Some(f) = self.faults.lock().unwrap().get_mut(key) {
                f.fail_appends -= 1;
            }
            return Err("injected store failure".into());
        }
        self.inner.append(key, update).await
    }
}

/// Counts awareness frames that reached the backend. With whispers working,
/// presence goes client to client and this stays at zero.
struct CountingBroadcaster {
    inner: HttpBroadcaster,
    awareness: AtomicUsize,
}

#[async_trait]
impl Broadcaster for CountingBroadcaster {
    async fn broadcast(&self, stream: &str, data: String) -> Result<(), BroadcastError> {
        let frame = serde_json::from_str::<Value>(&data)
            .ok()
            .and_then(|v| v["update"].as_str().and_then(|u| STANDARD.decode(u).ok()));
        if frame.is_some_and(|f| f.first() == Some(&1)) {
            self.awareness.fetch_add(1, Ordering::SeqCst);
        }
        self.inner.broadcast(stream, data).await
    }
}

#[derive(Clone)]
struct Demo {
    store: Arc<DemoStore>,
    broadcaster: Arc<CountingBroadcaster>,
    signer: GrantSigner,
}

#[derive(Deserialize)]
struct GrantQuery {
    doc: String,
    name: String,
    ttl: Option<i64>,
}

async fn grant(State(demo): State<Demo>, Query(q): Query<GrantQuery>) -> Json<Value> {
    Json(json!({ "grant": demo.signer.sign(&q.doc, &q.name, q.ttl.unwrap_or(3600)) }))
}

async fn document(State(demo): State<Demo>, Path(key): Path<String>) -> Json<Value> {
    let state = demo
        .store
        .load(&key)
        .await
        .ok()
        .flatten()
        .map(|s| STANDARD.encode(s));
    Json(json!({ "state": state, "updates": demo.store.inner.len(&key) }))
}

#[derive(Deserialize)]
struct FaultQuery {
    delay_ms: Option<u64>,
    fail_appends: Option<usize>,
}

async fn faults(
    State(demo): State<Demo>,
    Path(key): Path<String>,
    Query(q): Query<FaultQuery>,
) -> Json<Value> {
    let faults = Faults {
        delay_ms: q.delay_ms.unwrap_or(0),
        fail_appends: q.fail_appends.unwrap_or(0),
    };
    demo.store.faults.lock().unwrap().insert(key, faults);
    Json(json!({ "ok": true }))
}

async fn stats(State(demo): State<Demo>) -> Json<Value> {
    Json(json!({ "awareness_via_rpc": demo.broadcaster.awareness.load(Ordering::SeqCst) }))
}

fn env_or(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_string())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let rpc_addr: SocketAddr = env_or("YRBY_RPC_ADDR", "127.0.0.1:50051").parse()?;
    let http_addr: SocketAddr = env_or("YRBY_HTTP_ADDR", "127.0.0.1:3100").parse()?;
    let mut http = HttpBroadcaster::new(env_or(
        "ANYCABLE_BROADCAST_URL",
        "http://127.0.0.1:8090/_broadcast",
    ));
    if let Ok(key) = std::env::var("ANYCABLE_BROADCAST_KEY") {
        http = http.with_key(key);
    }
    let signer = GrantSigner::new(env_or("YRBY_GRANT_SECRET", "yrby-demo-grant-secret"));

    let store = Arc::new(DemoStore::default());
    let broadcaster = Arc::new(CountingBroadcaster {
        inner: http,
        awareness: AtomicUsize::new(0),
    });
    let channel =
        DocumentChannel::new(store.clone(), broadcaster.clone(), Arc::new(signer.clone()))
            .on_gap(|key| tracing::warn!(key, "document has an open causal gap"));
    let cable = Cable::new().channel(CHANNEL_NAME, channel);

    let demo = Demo {
        store,
        broadcaster,
        signer,
    };
    let api = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/grant", get(grant))
        .route("/stats", get(stats))
        .route("/documents/{key}", get(document))
        .route("/documents/{key}/faults", post(faults))
        .with_state(demo);

    let listener = tokio::net::TcpListener::bind(http_addr).await?;
    tracing::info!(%rpc_addr, %http_addr, "yrby AnyCable backend listening");
    let http_server = axum::serve(listener, api);
    let rpc_server = tonic::transport::Server::builder()
        .add_service(anycable_rpc::service(cable))
        .serve(rpc_addr);
    tokio::select! {
        result = http_server => result?,
        result = rpc_server => result?,
    }
    Ok(())
}
