#![allow(clippy::missing_errors_doc)]
use loco_rs::prelude::*;
use serde::Serialize;

/// How long a connection token lasts. Short, because the client refreshes it.
const TOKEN_TTL_SECONDS: i64 = 300;

#[derive(Serialize)]
pub struct CableToken {
    /// For the cable URL: `wss://…/cable?jid=<token>`. anycable-go verifies it
    /// and identifies the connection as the current user, without calling us.
    pub token: String,
}

/// A connection token for the logged-in user. Pages fetch it before
/// connecting, and again when anycable-go reports `token_expired`.
#[debug_handler]
pub async fn token(auth: auth::JWT, State(ctx): State<AppContext>) -> Result<Response> {
    let yrby = loco_yrby::Yrby::from_context(&ctx)?;
    format::json(CableToken {
        token: yrby.connection_token(&auth.claims.pid, TOKEN_TTL_SECONDS)?,
    })
}

pub fn routes() -> Routes {
    Routes::new().prefix("api/cable/").add("token", get(token))
}
