//! The Loco initializer: serves yrby's documents to anycable-go from the app.

use std::net::SocketAddr;
use std::sync::Arc;

use anycable_rpc::{Cable, HttpBroadcaster};
use async_trait::async_trait;
use axum::Router as AxumRouter;
use axum::extract::Path;
use axum::http::{HeaderMap, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use hmac::{Hmac, Mac};
use loco_rs::app::{AppContext, Initializer};
use loco_rs::doctor::{Check, CheckStatus};
use loco_rs::{Error, Result};
use sea_orm::{ConnectionTrait, DatabaseConnection, Statement};
use serde::Deserialize;
use serde_json::json;
use sha2::Sha256;
use tokio::net::TcpListener;
use yrby_anycable::{CHANNEL_NAME, DocumentChannel};
use yrby_core::engine::{DocumentAuthorizer, Identity};
use yrby_core::grant::GrantSigner;

use crate::collaborative::{Collaborative, RecordAuthorizer, Registry, Resolved, subject_for};
use crate::connection::{self, LocoLogin, USER_IDENTIFIER};
use crate::crypto::DocumentCipher;
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

/// `initializers.yrby` in `config/<env>.yaml`. Every setting has a default,
/// so the block can be left out.
///
/// ```yaml
/// initializers:
///   yrby:
///     encryption_key: <%= get_env(name="YRBY_ENCRYPTION_KEY", default="") %>
/// ```
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Settings {
    /// Where the app hands out grants (and, with AnyCable, connection tokens).
    pub routes_path: String,
    /// Signs grants. Defaults to one derived from the app's login secret.
    pub grant_secret: Option<String>,
    /// How long a grant lasts, in seconds. Grants are re-checked against the
    /// model's policy at every subscribe, so they can be long-lived.
    pub grant_ttl: i64,
    pub compact_every: u64,
    /// Where the login token is read from: a cookie, and a query parameter
    /// for apps that keep it in the browser.
    pub login_cookie: String,
    pub token_param: String,
    /// Accept connections that no user is identified on.
    pub allow_anonymous: bool,
    /// Encrypt documents at rest, the ones their models declare encrypted
    /// (`openssl rand -base64 32`). Empty leaves encryption off.
    pub encryption_key: String,
    /// Earlier keys, still accepted for reading while values re-encrypt.
    pub previous_encryption_keys: Vec<String>,
    pub anycable: AnyCableSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            routes_path: "/yrby".into(),
            grant_secret: None,
            grant_ttl: 7 * 24 * 60 * 60,
            compact_every: DEFAULT_COMPACT_EVERY,
            login_cookie: "auth_token".into(),
            token_param: "token".into(),
            allow_anonymous: false,
            encryption_key: String::new(),
            previous_encryption_keys: Vec::new(),
            anycable: AnyCableSettings::default(),
        }
    }
}

/// `initializers.yrby.anycable`: how the app and anycable-go reach each other.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AnyCableSettings {
    /// Where the gRPC service listens: anycable-go's `--rpc_host`. anycable-go
    /// sends no credentials over gRPC, so keep this on a private address.
    pub rpc_addr: SocketAddr,
    /// anycable-go's HTTP broadcast endpoint.
    pub broadcast_url: String,
    /// anycable-go's `--secret`. Signs connection tokens, and gives the
    /// broadcast key when `broadcast_key` is not set.
    pub secret: Option<String>,
    /// anycable-go's `--broadcast_key`, if set.
    pub broadcast_key: Option<String>,
    /// anycable-go's `--jwt_secret`, if it differs from `--secret`.
    pub jwt_secret: Option<String>,
    /// How long a connection token lasts, in seconds; the client refreshes it.
    pub token_ttl: i64,
}

impl Default for AnyCableSettings {
    fn default() -> Self {
        Self {
            rpc_addr: SocketAddr::from(([127, 0, 0, 1], 50051)),
            broadcast_url: "http://127.0.0.1:8080/_broadcast".into(),
            secret: None,
            broadcast_key: None,
            jwt_secret: None,
            token_ttl: 300,
        }
    }
}

impl Settings {
    /// The `initializers.yrby` block of the app's config, or the defaults.
    ///
    /// # Errors
    /// When the block is malformed.
    pub fn from_context(ctx: &AppContext) -> Result<Self> {
        match ctx
            .config
            .initializers
            .as_ref()
            .and_then(|initializers| initializers.get("yrby"))
        {
            Some(value) => serde_json::from_value(value.clone())
                .map_err(|e| Error::Message(format!("yrby: invalid config: {e}"))),
            None => Ok(Self::default()),
        }
    }

    fn grant_signer(&self, ctx: &AppContext) -> Result<GrantSigner> {
        if let Some(secret) = &self.grant_secret {
            return Ok(GrantSigner::new(secret));
        }
        // A key of its own, so a grant can never pass for a login token.
        let login = login_secret(ctx).ok_or_else(|| {
            Error::Message("yrby: set grant_secret, or auth.jwt.secret to derive it from".into())
        })?;
        let mut mac =
            Hmac::<Sha256>::new_from_slice(login.as_bytes()).expect("HMAC accepts any key length");
        mac.update(b"yrby grants");
        Ok(GrantSigner::new(hex::encode(mac.finalize().into_bytes())))
    }

    fn cipher(&self) -> Result<Option<DocumentCipher>> {
        if self.encryption_key.trim().is_empty() {
            return Ok(None);
        }
        DocumentCipher::new(&self.encryption_key, &self.previous_encryption_keys)
            .map(Some)
            .map_err(|e| Error::Message(format!("yrby: {e}")))
    }

    fn login(&self, ctx: &AppContext) -> LocoLogin {
        LocoLogin::new(
            login_secret(ctx).as_deref(),
            &self.login_cookie,
            &self.token_param,
            self.allow_anonymous,
        )
    }
}

/// What the initializer leaves in `ctx.shared_store` for the app's controllers.
#[derive(Clone)]
pub struct Yrby {
    signer: GrantSigner,
    grant_ttl: i64,
    anycable_jwt_secret: Option<String>,
}

impl Yrby {
    #[cfg(test)]
    pub(crate) fn new(signer: GrantSigner) -> Self {
        Self {
            signer,
            grant_ttl: Settings::default().grant_ttl,
            anycable_jwt_secret: None,
        }
    }

    /// A grant to `record`'s `name` document, for rendering into a page.
    /// Check that the user may edit the record first. Apps that fetch grants
    /// can use the crate's grant route instead, which runs the model's policy.
    ///
    /// # Errors
    /// When `name` is not one of the model's collaborative documents.
    pub fn grant_for<T: Collaborative>(&self, record: &T, name: &str) -> Result<String> {
        if !T::DOCUMENTS.contains(&name) {
            return Err(Error::BadRequest(format!(
                "{} has no collaborative document {name:?}",
                T::RECORD_TYPE
            )));
        }
        Ok(self.signer.sign(&subject_for(record), name, self.grant_ttl))
    }

    /// A token that identifies an anycable-go connection as the user
    /// `user_pid`. The crate's token route hands these out.
    ///
    /// # Errors
    /// When AnyCable's secret is not configured.
    pub fn connection_token(&self, user_pid: &str, ttl_seconds: i64) -> Result<String> {
        let secret = self.anycable_jwt_secret.as_deref().ok_or_else(|| {
            Error::Message("yrby: set anycable.secret to mint connection tokens".into())
        })?;
        Ok(connection::connection_token(secret, user_pid, ttl_seconds))
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
/// When the app starts its web server, it serves:
///
/// - AnyCable's gRPC service, at `anycable.rpc_addr`, for anycable-go, which
///   holds the browsers' WebSockets.
/// - `GET /yrby/grants/{record type}/{public id}/{name}`: a grant to that
///   document, for the logged-in user, if the model's policy allows it.
/// - `GET /yrby/token`: a connection token for the logged-in user, for
///   anycable-go.
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
    /// document key to open. The grant route is not served then.
    pub fn authorizer(mut self, authorizer: impl DocumentAuthorizer) -> Self {
        self.authorizer = Some(Arc::new(authorizer));
        self
    }
}

// GET {routes_path}/grants/{record_type}/{public_id}/{name}
async fn grant(
    registry: Registry,
    db: DatabaseConnection,
    login: Arc<LocoLogin>,
    yrby: Yrby,
    (record_type, public_id, name): (String, String, String),
    headers: HeaderMap,
    uri: Uri,
) -> Response {
    let user = login.user_of_request(&headers, &uri.to_string());
    let identity = Identity::new(match &user {
        Some(pid) => json!({ USER_IDENTIFIER: pid }),
        None => json!({}),
    });
    match registry
        .resolve(&db, &identity, &record_type, &public_id, &name)
        .await
    {
        Resolved::Allowed(_) => {
            let subject = format!("{record_type}/{public_id}");
            let grant = yrby.signer.sign(&subject, &name, yrby.grant_ttl);
            axum::Json(json!({ "grant": grant })).into_response()
        }
        Resolved::Refused if user.is_none() => StatusCode::UNAUTHORIZED.into_response(),
        Resolved::Refused => StatusCode::FORBIDDEN.into_response(),
        Resolved::Missing => StatusCode::NOT_FOUND.into_response(),
    }
}

// GET {routes_path}/token
async fn token(
    login: Arc<LocoLogin>,
    yrby: Yrby,
    ttl: i64,
    headers: HeaderMap,
    uri: Uri,
) -> Response {
    let Some(user) = login.user_of_request(&headers, &uri.to_string()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    match yrby.connection_token(&user, ttl) {
        Ok(token) => axum::Json(json!({ "token": token })).into_response(),
        Err(error) => (StatusCode::INTERNAL_SERVER_ERROR, error.to_string()).into_response(),
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
        let anycable = settings.anycable.clone();
        ctx.shared_store.insert(Yrby {
            signer: settings.grant_signer(ctx)?,
            grant_ttl: settings.grant_ttl,
            anycable_jwt_secret: anycable.jwt_secret.or(anycable.secret),
        });
        Ok(())
    }

    // Loco calls this only when it starts the web server, so the routes and
    // the RPC service run alongside it and not in worker or task processes.
    async fn after_routes(&self, router: AxumRouter, ctx: &AppContext) -> Result<AxumRouter> {
        let settings = Settings::from_context(ctx)?;
        let yrby = Yrby::from_context(ctx)?;
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
        let authorizer: Arc<dyn DocumentAuthorizer> = match &self.authorizer {
            Some(authorizer) => authorizer.clone(),
            None => {
                if self.registry.is_empty() {
                    tracing::warn!(
                        "[yrby] no collaborative models registered: every subscription will be refused"
                    );
                }
                Arc::new(RecordAuthorizer {
                    signer: yrby.signer.clone(),
                    registry: self.registry.clone(),
                    store: store.clone(),
                    db: ctx.db.clone(),
                })
            }
        };

        let mut router = router;
        let routes = settings.routes_path.trim_end_matches('/').to_string();
        let login = Arc::new(settings.login(ctx));
        if self.authorizer.is_none() {
            let (registry, db, login, yrby) = (
                self.registry.clone(),
                ctx.db.clone(),
                login.clone(),
                yrby.clone(),
            );
            router = router.route(
                &format!("{routes}/grants/{{record_type}}/{{public_id}}/{{name}}"),
                get(
                    move |Path(path): Path<(String, String, String)>,
                          headers: HeaderMap,
                          uri: Uri| {
                        grant(registry, db, login, yrby, path, headers, uri)
                    },
                ),
            );
        }

        let any = &settings.anycable;
        let mut broadcaster = HttpBroadcaster::new(&any.broadcast_url);
        if let Some(key) = any.broadcast_key.clone().or_else(|| {
            any.secret
                .as_deref()
                .map(anycable_rpc::secret::broadcast_key)
        }) {
            broadcaster = broadcaster.with_key(key);
        }
        let channel = DocumentChannel::new(Arc::new(store), Arc::new(broadcaster), authorizer)
            .on_gap(|key| tracing::warn!(key, "[yrby] document has an open causal gap"));
        let cable = Cable::new()
            .authenticator(settings.login(ctx))
            .channel(CHANNEL_NAME, channel);

        let (login, yrby, ttl) = (login.clone(), yrby.clone(), any.token_ttl);
        router = router.route(
            &format!("{routes}/token"),
            get(move |headers: HeaderMap, uri: Uri| token(login, yrby, ttl, headers, uri)),
        );

        // Bind now, so a taken port fails the boot instead of a background task.
        let listener = TcpListener::bind(any.rpc_addr)
            .await
            .map_err(|e| Error::Message(format!("yrby: cannot listen on {}: {e}", any.rpc_addr)))?;
        tracing::info!(addr = %any.rpc_addr, "[yrby] AnyCable RPC listening");
        // A second server, not a job: it lives exactly as long as the web
        // server beside it, and stops on the same signal.
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
        let settings = match Settings::from_context(ctx) {
            Ok(settings) => settings,
            Err(error) => {
                return Ok(Some(Check {
                    status: CheckStatus::NotOk,
                    message: error.to_string(),
                    description: None,
                }));
            }
        };
        if let Err(error) = settings.grant_signer(ctx).and(settings.cipher()) {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(yaml: serde_json::Value) -> std::result::Result<Settings, serde_json::Error> {
        serde_json::from_value(yaml)
    }

    #[test]
    fn everything_has_a_default() {
        let settings = parse(json!({})).unwrap();
        assert_eq!(settings.routes_path, "/yrby");
        assert!(settings.grant_secret.is_none());
        assert!(
            settings.cipher().unwrap().is_none(),
            "encryption is off by default"
        );
        assert_eq!(settings.anycable.rpc_addr.port(), 50051);
    }

    #[test]
    fn reads_anycable_and_encryption_and_refuses_typos() {
        let settings = parse(json!({
            "encryption_key": "q0b3cxVvT6s0w8m3k4b0w2bX8y0pZ8b0YxK2l9p3n1o=",
            "anycable": { "secret": "s", "rpc_addr": "127.0.0.1:6000" }
        }))
        .unwrap();
        assert_eq!(settings.anycable.rpc_addr.port(), 6000);
        assert!(settings.cipher().unwrap().is_some());

        assert!(parse(json!({ "transport": "embedded" })).is_err());
        assert!(parse(json!({ "anycable": { "secrt": "s" } })).is_err());
        assert!(
            parse(json!({ "encryption_key": "short" }))
                .unwrap()
                .cipher()
                .is_err()
        );
    }
}
