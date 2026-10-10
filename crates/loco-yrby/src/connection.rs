//! Who is on the other end of a WebSocket.
//!
//! anycable-go identifies a connection one of two ways, and both end with the
//! same connection identifiers, `{"user": "<pid>"}`, which every later command
//! carries and [`connected_user`] reads:
//!
//! 1. **AnyCable JWT identification** (preferred). The page asks the app for a
//!    [`crate::Yrby::connection_token`] and connects with
//!    `wss://…/cable?jid=<token>`. anycable-go verifies the token itself (it
//!    is signed with anycable-go's `--secret`) and takes the identifiers from
//!    its `ext` claim, with no RPC call. An expired token is refused with
//!    `{"type":"disconnect","reason":"token_expired"}`, and `@anycable/web`'s
//!    token refresher fetches a new one.
//! 2. **The login cookie**, for connections without a token. anycable-go calls
//!    the backend's `connect` RPC with the request's cookies, and
//!    [`LoginCookie`] validates the Loco login JWT found there, as a Rails
//!    `ApplicationCable::Connection` reads `cookies.encrypted`.

use anycable_rpc::proto::Env;
use anycable_rpc::{Authenticator, RpcMeta};
use async_trait::async_trait;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use serde::Serialize;
use serde_json::{Value, json};
use yrby_core::engine::Identity;

/// The connection identifier that holds the user's pid.
pub const USER_IDENTIFIER: &str = "user";

/// The pid of the user this connection was identified as, if any.
pub fn connected_user(identity: &Identity) -> Option<&str> {
    identity.get(USER_IDENTIFIER)
}

#[derive(Serialize)]
struct AnyCableClaims {
    /// The connection identifiers, JSON-encoded, as anycable-go expects.
    ext: String,
    exp: i64,
}

/// An AnyCable identification token for `user_pid`, signed with anycable-go's
/// `--secret` (or `--jwt_secret`).
pub(crate) fn connection_token(secret: &str, user_pid: &str, ttl_seconds: i64) -> String {
    let claims = AnyCableClaims {
        ext: json!({ USER_IDENTIFIER: user_pid }).to_string(),
        exp: chrono::Utc::now().timestamp() + ttl_seconds,
    };
    encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .expect("HS256 signing cannot fail")
}

/// Identifies a token-less connection by the Loco login JWT in its cookies.
pub struct LoginCookie {
    login: Option<(loco_rs::auth::jwt::JWT, String)>,
    allow_anonymous: bool,
}

impl LoginCookie {
    /// `login_secret` is the app's `auth.jwt.secret`; `cookie` the cookie that
    /// holds the login token (Loco's cookie location, such as `auth_token`).
    pub fn new(login_secret: &str, cookie: impl Into<String>, allow_anonymous: bool) -> Self {
        Self {
            login: Some((loco_rs::auth::jwt::JWT::new(login_secret), cookie.into())),
            allow_anonymous,
        }
    }

    /// No cookie identification: token-less connections are anonymous, and
    /// accepted only if `allow_anonymous`.
    pub fn none(allow_anonymous: bool) -> Self {
        Self {
            login: None,
            allow_anonymous,
        }
    }

    fn user(&self, env: &Env) -> Option<String> {
        let (jwt, cookie) = self.login.as_ref()?;
        let header = env
            .headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("cookie"))?
            .1;
        let token = header.split(';').find_map(|pair| {
            let (name, value) = pair.trim().split_once('=')?;
            (name == cookie).then_some(value)
        })?;
        Some(jwt.validate(token).ok()?.claims.pid)
    }
}

#[async_trait]
impl Authenticator for LoginCookie {
    async fn connect(&self, _meta: &RpcMeta, env: &Env) -> Option<Value> {
        match self.user(env) {
            Some(pid) => Some(json!({ USER_IDENTIFIER: pid })),
            None if self.allow_anonymous => Some(json!({})),
            None => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{DecodingKey, Validation, decode};
    use serde_json::Map;

    // Loco decodes its login secret as base64.
    const LOGIN_SECRET: &str = "bG9naW4tc2VjcmV0LWZvci10ZXN0cw==";

    fn env_with_cookie(cookie: &str) -> Env {
        Env {
            headers: [("cookie".to_string(), cookie.to_string())].into(),
            ..Default::default()
        }
    }

    #[test]
    fn mints_the_token_anycable_go_verifies() {
        let token = connection_token("anycable-secret", "pid-1", 60);
        let mut validation = Validation::new(Algorithm::HS256);
        validation.validate_aud = false;
        let claims = decode::<Value>(
            &token,
            &DecodingKey::from_secret(b"anycable-secret"),
            &validation,
        )
        .unwrap()
        .claims;
        // `ext` is a JSON string, not an object: anycable-go requires that.
        assert_eq!(claims["ext"], json!(r#"{"user":"pid-1"}"#));
        assert!(claims["exp"].as_i64().unwrap() > chrono::Utc::now().timestamp());
    }

    #[tokio::test]
    async fn identifies_a_connection_by_its_login_cookie() {
        let login = loco_rs::auth::jwt::JWT::new(LOGIN_SECRET)
            .generate_token(60, "pid-7".into(), Map::new())
            .unwrap();
        let auth = LoginCookie::new(LOGIN_SECRET, "auth_token", false);
        let meta = RpcMeta::default();

        let env = env_with_cookie(&format!("theme=dark; auth_token={login}; other=1"));
        assert_eq!(
            auth.connect(&meta, &env).await,
            Some(json!({ "user": "pid-7" }))
        );

        // No cookie, a forged one, or another app's: refused.
        assert_eq!(auth.connect(&meta, &Env::default()).await, None);
        assert_eq!(
            auth.connect(&meta, &env_with_cookie("auth_token=forged"))
                .await,
            None
        );
        let other = loco_rs::auth::jwt::JWT::new("b3RoZXItc2VjcmV0")
            .generate_token(60, "pid-7".into(), Map::new())
            .unwrap();
        assert_eq!(
            auth.connect(&meta, &env_with_cookie(&format!("auth_token={other}")))
                .await,
            None
        );

        // Unless anonymous connections are allowed: then they carry no user.
        let open = LoginCookie::new(LOGIN_SECRET, "auth_token", true);
        assert_eq!(open.connect(&meta, &Env::default()).await, Some(json!({})));
    }
}
