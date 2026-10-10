//! Publishing to anycable-go streams.
//!
//! anycable-go delivers a publication to every client subscribed to its
//! stream, on every node. [`HttpBroadcaster`] uses its HTTP broadcast adapter
//! (`--broadcast_adapter=http`); a Redis or NATS publisher can implement
//! [`Broadcaster`] the same way.

use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;

pub type BroadcastError = Box<dyn std::error::Error + Send + Sync>;

#[async_trait]
pub trait Broadcaster: Send + Sync + 'static {
    /// Publish `data` (usually a JSON-encoded message) to `stream`. Returns
    /// once anycable-go has accepted it.
    async fn broadcast(&self, stream: &str, data: String) -> Result<(), BroadcastError>;
}

/// Publishes through anycable-go's HTTP broadcast endpoint.
#[derive(Clone)]
pub struct HttpBroadcaster {
    url: String,
    key: Option<String>,
    client: reqwest::Client,
}

#[derive(Serialize)]
struct Publication<'a> {
    stream: &'a str,
    data: &'a str,
}

impl HttpBroadcaster {
    /// `url` is the full endpoint, such as `http://localhost:8090/_broadcast`.
    pub fn new(url: impl Into<String>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("an HTTP client with default settings builds");
        Self {
            url: url.into(),
            key: None,
            client,
        }
    }

    /// Authenticate with anycable-go's `--broadcast_key`, or with
    /// [`crate::secret::broadcast_key`] of its `--secret`.
    pub fn with_key(mut self, key: impl Into<String>) -> Self {
        self.key = Some(key.into());
        self
    }
}

#[async_trait]
impl Broadcaster for HttpBroadcaster {
    async fn broadcast(&self, stream: &str, data: String) -> Result<(), BroadcastError> {
        let body = serde_json::to_vec(&Publication {
            stream,
            data: &data,
        })?;
        let mut request = self
            .client
            .post(&self.url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body);
        if let Some(key) = &self.key {
            request = request.bearer_auth(key);
        }
        let response = request.send().await?;
        if !response.status().is_success() {
            return Err(format!("anycable-go refused the broadcast: {}", response.status()).into());
        }
        Ok(())
    }
}
