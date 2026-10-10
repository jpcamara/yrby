//! The Loco initializer: serves yrby's document channel to anycable-go.

use std::net::SocketAddr;
use std::sync::Arc;

use anycable_rpc::{Cable, HttpBroadcaster};
use async_trait::async_trait;
use axum::Router as AxumRouter;
use loco_rs::app::{AppContext, Initializer};
use loco_rs::doctor::{Check, CheckStatus};
use loco_rs::{Error, Result};
use sea_orm::{ConnectionTrait, Statement};
use serde::Deserialize;
use tokio::net::TcpListener;
use yrby_anycable::{CHANNEL_NAME, DocumentChannel};
use yrby_core::engine::DocumentAuthorizer;
use yrby_core::grant::GrantSigner;

use crate::collaborative::{Collaborative, RecordAuthorizer, Registry, subject_for};
use crate::connection::{self, LoginCookie};
use crate::crypto::{DocumentCipher, HashDigest};
use crate::store::{DEFAULT_COMPACT_EVERY, SeaOrmStore};

/// The app's login JWT secret, `auth.jwt.secret`.
fn login_secret(ctx: &AppContext) -> Option<String> {
    ctx.config
        .auth
        .as_ref()?
        .jwt
        .as_ref()
        .map(|jwt| jwt.secret.clone())
}

/// `initializers.yrby` in `config/<env>.yaml`.
///
/// ```yaml
/// initializers:
///   yrby:
///     rpc_addr: 127.0.0.1:50051       # anycable-go's --rpc_host
///     broadcast_url: http://127.0.0.1:8080/_broadcast
///     anycable_secret: <%= get_env(name="ANYCABLE_SECRET") %>  # or broadcast_key
///     grant_secret: <%= get_env(name="YRBY_GRANT_SECRET") %>
///     compact_every: 64
/// ```
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    /// Where the gRPC service listens. anycable-go has no credentials for
    /// gRPC, so keep this on a private address.
    #[serde(default = "default_rpc_addr")]
    pub rpc_addr: SocketAddr,
    /// anycable-go's HTTP broadcast endpoint.
    pub broadcast_url: String,
    /// anycable-go's `--broadcast_key`.
    pub broadcast_key: Option<String>,
    /// anycable-go's `--secret`, to derive the broadcast key from, when
    /// `broadcast_key` is not set.
    pub anycable_secret: Option<String>,
    /// Signs grants. Use a secret of its own.
    pub grant_secret: String,
    #[serde(default = "default_compact_every")]
    pub compact_every: u64,
    /// The secret anycable-go verifies connection tokens with: its
    /// `--jwt_secret`, which defaults to its `--secret`. Defaults to
    /// `anycable_secret`.
    pub anycable_jwt_secret: Option<String>,
    /// The cookie that holds the Loco login token, for connections that
    /// arrive without a connection token. Unset turns cookie identification off.
    #[serde(default = "default_login_cookie")]
    pub login_cookie: Option<String>,
    /// Accept connections no one is identified on. Off by default: an
    /// unidentified connection is refused before it can subscribe.
    #[serde(default)]
    pub allow_anonymous: bool,
    /// Encrypt documents at rest, in Active Record encryption's format. Which
    /// documents are encrypted is up to their models
    /// ([`Collaborative::ENCRYPTED`]).
    pub encryption: Option<EncryptionSettings>,
}

/// `initializers.yrby.encryption`: Active Record encryption's settings.
///
/// ```yaml
/// encryption:
///   primary_key: <%= get_env(name="AR_ENCRYPTION_PRIMARY_KEY") %>   # or a list, newest last
///   key_derivation_salt: <%= get_env(name="AR_ENCRYPTION_KEY_DERIVATION_SALT") %>
///   hash_digest_class: SHA256   # or SHA1
/// ```
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EncryptionSettings {
    #[serde(deserialize_with = "one_or_many")]
    pub primary_key: Vec<String>,
    pub key_derivation_salt: String,
    #[serde(default)]
    pub hash_digest_class: HashDigest,
}

fn one_or_many<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Vec<String>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum OneOrMany {
        One(String),
        Many(Vec<String>),
    }
    Ok(match OneOrMany::deserialize(deserializer)? {
        OneOrMany::One(key) => vec![key],
        OneOrMany::Many(keys) => keys,
    })
}

fn default_login_cookie() -> Option<String> {
    Some("auth_token".to_string())
}

fn default_rpc_addr() -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], 50051))
}

fn default_compact_every() -> u64 {
    DEFAULT_COMPACT_EVERY
}

impl Settings {
    /// The `initializers.yrby` block of the app's config.
    ///
    /// # Errors
    /// When the block is missing or malformed.
    pub fn from_context(ctx: &AppContext) -> Result<Self> {
        let value = ctx
            .config
            .initializers
            .as_ref()
            .and_then(|initializers| initializers.get("yrby"))
            .ok_or_else(|| {
                Error::Message("yrby: missing `initializers.yrby` in the config".into())
            })?;
        serde_json::from_value(value.clone())
            .map_err(|e| Error::Message(format!("yrby: invalid config: {e}")))
    }

    fn jwt_secret(&self) -> Option<String> {
        self.anycable_jwt_secret
            .clone()
            .or_else(|| self.anycable_secret.clone())
    }

    fn cipher(&self) -> Result<Option<DocumentCipher>> {
        // An empty primary key (an unset env var) leaves encryption off.
        let Some(encryption) = self
            .encryption
            .as_ref()
            .filter(|e| e.primary_key.iter().any(|k| !k.trim().is_empty()))
        else {
            return Ok(None);
        };
        DocumentCipher::new(
            &encryption.primary_key,
            &encryption.key_derivation_salt,
            encryption.hash_digest_class,
        )
        .map(Some)
        .map_err(|e| Error::Message(format!("yrby: {e}")))
    }

    fn broadcast_key(&self) -> Option<String> {
        self.broadcast_key.clone().or_else(|| {
            self.anycable_secret
                .as_deref()
                .map(anycable_rpc::secret::broadcast_key)
        })
    }
}

/// What the initializer leaves in `ctx.shared_store` for the app's controllers.
#[derive(Clone)]
pub struct Yrby {
    signer: GrantSigner,
    anycable_jwt_secret: Option<String>,
}

impl Yrby {
    pub(crate) fn new(signer: GrantSigner) -> Self {
        Self {
            signer,
            anycable_jwt_secret: None,
        }
    }

    /// A token that identifies a connection as the user `user_pid`, for the
    /// cable URL (`?jid=<token>`). anycable-go verifies it without calling the
    /// app. Keep `ttl_seconds` short and let the client refresh it.
    ///
    /// # Errors
    /// When neither `anycable_jwt_secret` nor `anycable_secret` is configured.
    pub fn connection_token(&self, user_pid: &str, ttl_seconds: i64) -> Result<String> {
        let secret = self.anycable_jwt_secret.as_deref().ok_or_else(|| {
            Error::Message(
                "yrby: set anycable_secret or anycable_jwt_secret to mint connection tokens".into(),
            )
        })?;
        Ok(connection::connection_token(secret, user_pid, ttl_seconds))
    }

    /// A grant to `record`'s `name` document, valid for `ttl_seconds`. Render
    /// it into the page (the `<yrby-document grant>` attribute), and return a
    /// fresh one from the page's refresh endpoint. Check that the user may
    /// edit the record before minting one: the grant is the permission.
    ///
    /// # Errors
    /// When `name` is not one of the model's collaborative documents.
    pub fn grant_for<T: Collaborative>(
        &self,
        record: &T,
        name: &str,
        ttl_seconds: i64,
    ) -> Result<String> {
        if !T::DOCUMENTS.contains(&name) {
            return Err(Error::BadRequest(format!(
                "{} has no collaborative document {name:?}",
                T::RECORD_TYPE
            )));
        }
        Ok(self.signer.sign(&subject_for(record), name, ttl_seconds))
    }

    /// The `Yrby` the initializer stored.
    ///
    /// # Errors
    /// When `YrbyInitializer` is not registered.
    pub fn from_context(ctx: &AppContext) -> Result<Self> {
        ctx.shared_store.get::<Yrby>().ok_or_else(|| {
            Error::Message("yrby: YrbyInitializer is not registered in Hooks::initializers".into())
        })
    }
}

/// Register in `Hooks::initializers`:
///
/// ```ignore
/// async fn initializers(_ctx: &AppContext) -> Result<Vec<Box<dyn Initializer>>> {
///     Ok(vec![Box::new(loco_yrby::YrbyInitializer::new().collaborative::<posts::Model>())])
/// }
/// ```
///
/// It stores a [`Yrby`] (for minting grants) in `ctx.shared_store`, and when
/// the app starts its server, it serves the document channel over gRPC on
/// `rpc_addr`, with documents in the app's database.
#[derive(Default)]
pub struct YrbyInitializer {
    registry: Registry,
    authorizer: Option<Arc<dyn DocumentAuthorizer>>,
}

impl YrbyInitializer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Let grants open `T`'s collaborative documents. Grants for any model
    /// not registered here are refused.
    pub fn collaborative<T: Collaborative>(mut self) -> Self {
        self.registry.register::<T>();
        self
    }

    /// Replace record grants with your own policy entirely, for documents that
    /// do not belong to a record (a room key, say). The authorizer returns the
    /// document key to open.
    pub fn authorizer(mut self, authorizer: impl DocumentAuthorizer) -> Self {
        self.authorizer = Some(Arc::new(authorizer));
        self
    }
}

#[async_trait]
impl Initializer for YrbyInitializer {
    fn name(&self) -> String {
        "yrby".to_string()
    }

    // Every mode (server, worker, task) can mint grants.
    async fn before_run(&self, ctx: &AppContext) -> Result<()> {
        let settings = Settings::from_context(ctx)?;
        let mut yrby = Yrby::new(GrantSigner::new(&settings.grant_secret));
        yrby.anycable_jwt_secret = settings.jwt_secret();
        ctx.shared_store.insert(yrby);
        Ok(())
    }

    // Loco calls this only when it starts the web server, so the RPC service
    // runs alongside the server and not in worker or task processes.
    async fn after_routes(&self, router: AxumRouter, ctx: &AppContext) -> Result<AxumRouter> {
        let settings = Settings::from_context(ctx)?;
        let mut store = SeaOrmStore::new(ctx.db.clone()).compact_every(settings.compact_every);
        if let Some(cipher) = settings.cipher()? {
            store = store.encryption(cipher);
            // Record documents are encrypted per attribute, as their models
            // declare. A custom authorizer's documents have no model to ask,
            // so then every document is encrypted.
            if self.authorizer.is_none() {
                store = store.encrypt_documents(self.registry.encryption_policy());
            }
        }
        let mut broadcaster = HttpBroadcaster::new(&settings.broadcast_url);
        if let Some(key) = settings.broadcast_key() {
            broadcaster = broadcaster.with_key(key);
        }
        let authorizer: Arc<dyn DocumentAuthorizer> = match &self.authorizer {
            Some(authorizer) => authorizer.clone(),
            None => {
                if self.registry.is_empty() {
                    tracing::warn!(
                        "[yrby] no collaborative models registered: every subscription will be refused"
                    );
                }
                Arc::new(RecordAuthorizer {
                    signer: GrantSigner::new(&settings.grant_secret),
                    registry: self.registry.clone(),
                    store: store.clone(),
                    db: ctx.db.clone(),
                })
            }
        };
        let channel = DocumentChannel::new(Arc::new(store), Arc::new(broadcaster), authorizer)
            .on_gap(|key| tracing::warn!(key, "[yrby] document has an open causal gap"));
        // Token-less connections: the login cookie, or nothing.
        let authenticator = match (settings.login_cookie.as_deref(), login_secret(ctx)) {
            (Some(cookie), Some(secret)) => {
                LoginCookie::new(&secret, cookie, settings.allow_anonymous)
            }
            _ => LoginCookie::none(settings.allow_anonymous),
        };
        let cable = Cable::new()
            .authenticator(authenticator)
            .channel(CHANNEL_NAME, channel);

        // Bind now, so a taken port fails the boot instead of a background task.
        let listener = TcpListener::bind(settings.rpc_addr).await.map_err(|e| {
            Error::Message(format!("yrby: cannot listen on {}: {e}", settings.rpc_addr))
        })?;
        tracing::info!(addr = %settings.rpc_addr, "[yrby] AnyCable RPC listening");
        // A second server, not a job: it lives exactly as long as the web
        // server beside it, and stops on the same signal (Ctrl-C or SIGTERM),
        // finishing the calls in flight.
        tokio::spawn(async move {
            let incoming = tonic::transport::server::TcpIncoming::from(listener);
            let served = tonic::transport::Server::builder()
                .add_service(anycable_rpc::service(cable))
                .serve_with_incoming_shutdown(incoming, loco_rs::boot::shutdown_signal())
                .await;
            match served {
                Ok(()) => tracing::info!("[yrby] AnyCable RPC stopped"),
                Err(error) => tracing::error!(%error, "[yrby] AnyCable RPC server failed"),
            }
        });
        Ok(router)
    }

    async fn check(&self, ctx: &AppContext) -> Result<Option<Check>> {
        if let Err(error) = Settings::from_context(ctx) {
            return Ok(Some(Check {
                status: CheckStatus::NotOk,
                message: error.to_string(),
                description: None,
            }));
        }
        let probe = Statement::from_string(
            ctx.db.get_database_backend(),
            "SELECT 1 FROM y_documents, y_document_updates LIMIT 1",
        );
        Ok(Some(match ctx.db.query_all_raw(probe).await {
            Ok(_) => Check {
                status: CheckStatus::Ok,
                message: "yrby: tables present".into(),
                description: None,
            },
            Err(error) => Check {
                status: CheckStatus::NotOk,
                message: "yrby: tables missing".into(),
                description: Some(format!(
                    "Add loco_yrby::migration::CreateYTables to your Migrator and run `cargo loco db migrate` ({error})"
                )),
            },
        }))
    }
}
