//! Who is on the other end of a WebSocket, or of a grant request.
//!
//! Every way in ends with the same connection identifiers, `{"user": "<pid>"}`,
//! which every later command carries and [`connected_user`] reads.
//!
//! - **Loco's own login** ([`LocoLogin`]). The app's login JWT, from the
//!   `auth_token` cookie (a same-origin page sends it with the WebSocket), a
//!   `?token=` query parameter (apps that keep the token in the browser, as
//!   Loco's React starter does), or a `Bearer` header (grant requests).
//! - **AnyCable JWT identification**, with the AnyCable transport. The page
//!   connects to anycable-go with `?jid=<token>` from
//!   [`crate::Yrby::connection_token`], and anycable-go identifies the
//!   connection itself, with no call to the app. Connections without a token
//!   fall back to the login cookie through anycable-go's connect call.

use anycable_rpc::proto::Env;
use anycable_rpc::{Authenticator, RpcMeta};
use async_trait::async_trait;
use axum::http::HeaderMap;
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

/// Identifies a request by the Loco app's own login JWT.
pub struct LocoLogin {
    jwt: Option<loco_rs::auth::jwt::JWT>,
    cookie: String,
    token_param: String,
    allow_anonymous: bool,
}

impl LocoLogin {
    /// `login_secret` is the app's `auth.jwt.secret`. The token is read from
    /// the `cookie` cookie or the `token_param` query parameter (and, for
    /// plain HTTP requests, a `Bearer` header).
    pub fn new(
        login_secret: Option<&str>,
        cookie: impl Into<String>,
        token_param: impl Into<String>,
        allow_anonymous: bool,
    ) -> Self {
        Self {
            jwt: login_secret.map(loco_rs::auth::jwt::JWT::new),
            cookie: cookie.into(),
            token_param: token_param.into(),
            allow_anonymous,
        }
    }

    fn validate(&self, token: &str) -> Option<String> {
        Some(self.jwt.as_ref()?.validate(token).ok()?.claims.pid)
    }

    fn user_in_cookie(&self, header: &str) -> Option<String> {
        let token = header.split(';').find_map(|pair| {
            let (name, value) = pair.trim().split_once('=')?;
            (name == self.cookie).then_some(value)
        })?;
        self.validate(token)
    }

    fn user_in_query(&self, url: &str) -> Option<String> {
        let (_, query) = url.split_once('?')?;
        let token = query.split('&').find_map(|pair| {
            let (name, value) = pair.split_once('=')?;
            (name == self.token_param).then_some(value)
        })?;
        self.validate(token)
    }

    /// The pid of the user an HTTP request is logged in as: a `Bearer` header,
    /// the login cookie, or the token query parameter.
    pub fn user_of_request(&self, headers: &HeaderMap, url: &str) -> Option<String> {
        let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
        header("authorization")
            .and_then(|v| v.strip_prefix("Bearer "))
            .and_then(|token| self.validate(token))
            .or_else(|| header("cookie").and_then(|c| self.user_in_cookie(c)))
            .or_else(|| self.user_in_query(url))
    }

    fn user_of_connection(&self, env: &Env) -> Option<String> {
        env.headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("cookie"))
            .and_then(|(_, cookie)| self.user_in_cookie(cookie))
            .or_else(|| self.user_in_query(&env.url))
    }
}

#[async_trait]
impl Authenticator for LocoLogin {
    async fn connect(&self, _meta: &RpcMeta, env: &Env) -> Option<Value> {
        match self.user_of_connection(env) {
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

    fn login(pid: &str, secret: &str) -> String {
        loco_rs::auth::jwt::JWT::new(secret)
            .generate_token(60, pid.into(), Map::new())
            .unwrap()
    }

    fn env(cookie: Option<&str>, url: &str) -> Env {
        Env {
            url: url.to_string(),
            headers: cookie
                .map(|c| [("cookie".to_string(), c.to_string())].into())
                .unwrap_or_default(),
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
    async fn identifies_a_connection_by_cookie_or_query_token() {
        let auth = LocoLogin::new(Some(LOGIN_SECRET), "auth_token", "token", false);
        let meta = RpcMeta::default();
        let user = Some(json!({ "user": "pid-7" }));
        let token = login("pid-7", LOGIN_SECRET);

        let cookie = format!("theme=dark; auth_token={token}; other=1");
        assert_eq!(
            auth.connect(&meta, &env(Some(&cookie), "/yrby/cable"))
                .await,
            user
        );
        let url = format!("/yrby/cable?x=1&token={token}");
        assert_eq!(auth.connect(&meta, &env(None, &url)).await, user);

        // No token, a forged one, or another app's: refused.
        assert_eq!(auth.connect(&meta, &env(None, "/yrby/cable")).await, None);
        assert_eq!(
            auth.connect(&meta, &env(None, "/yrby/cable?token=forged"))
                .await,
            None
        );
        let other = login("pid-7", "b3RoZXItc2VjcmV0");
        let url = format!("/yrby/cable?token={other}");
        assert_eq!(auth.connect(&meta, &env(None, &url)).await, None);

        // Unless anonymous connections are allowed: then they carry no user.
        let open = LocoLogin::new(Some(LOGIN_SECRET), "auth_token", "token", true);
        assert_eq!(
            open.connect(&meta, &env(None, "/yrby/cable")).await,
            Some(json!({}))
        );
        // An app without a login secret identifies no one.
        let none = LocoLogin::new(None, "auth_token", "token", false);
        assert_eq!(none.connect(&meta, &env(Some(&cookie), "/")).await, None);
    }

    #[test]
    fn identifies_a_request_by_bearer_cookie_or_query() {
        let auth = LocoLogin::new(Some(LOGIN_SECRET), "auth_token", "token", false);
        let token = login("pid-9", LOGIN_SECRET);
        let mut headers = HeaderMap::new();
        headers.insert("authorization", format!("Bearer {token}").parse().unwrap());
        assert_eq!(auth.user_of_request(&headers, "/"), Some("pid-9".into()));

        let mut headers = HeaderMap::new();
        headers.insert("cookie", format!("auth_token={token}").parse().unwrap());
        assert_eq!(auth.user_of_request(&headers, "/"), Some("pid-9".into()));

        let url = format!("/yrby/grants?token={token}");
        assert_eq!(
            auth.user_of_request(&HeaderMap::new(), &url),
            Some("pid-9".into())
        );
        assert_eq!(auth.user_of_request(&HeaderMap::new(), "/"), None);
    }
}
