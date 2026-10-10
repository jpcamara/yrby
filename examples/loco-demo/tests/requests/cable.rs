use loco_rs::testing::prelude::*;
use serial_test::serial;
use yrby_loco::app::App;

use super::prepare_data;

// The test config's initializers.yrby.anycable_secret: anycable-go verifies
// connection tokens with its --secret.
const ANYCABLE_SECRET: &str = "yrby-test-anycable-secret";

#[tokio::test]
#[serial]
async fn issues_a_connection_token_for_the_user() {
    request::<App, _, _>(|request, ctx| async move {
        let user = prepare_data::init_user_login(&request, &ctx).await;
        let (key, value) = prepare_data::auth_header(&user.token);
        let res = request.get("/api/cable/token").add_header(key, value).await;
        assert_eq!(res.status_code(), 200);
        let token = res.json::<serde_json::Value>()["token"]
            .as_str()
            .unwrap()
            .to_string();

        // What anycable-go checks: HS256 with its secret, an `exp`, and the
        // identifiers as a JSON string in `ext`.
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
        validation.validate_aud = false;
        let claims = jsonwebtoken::decode::<serde_json::Value>(
            &token,
            &jsonwebtoken::DecodingKey::from_secret(ANYCABLE_SECRET.as_bytes()),
            &validation,
        )
        .unwrap()
        .claims;
        let ext: serde_json::Value = serde_json::from_str(claims["ext"].as_str().unwrap()).unwrap();
        assert_eq!(
            ext,
            serde_json::json!({ "user": user.user.pid.to_string() })
        );
    })
    .await;
}

#[tokio::test]
#[serial]
async fn requires_a_login() {
    request::<App, _, _>(|request, _ctx| async move {
        assert_eq!(request.get("/api/cable/token").await.status_code(), 401);
    })
    .await;
}
