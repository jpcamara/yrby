use loco_rs::testing::prelude::*;
use serial_test::serial;
use yrby_loco::app::App;

use super::prepare_data;

fn claims(grant: &str) -> serde_json::Value {
    use base64::Engine;
    let payload = grant.split('.').nth(1).unwrap();
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
#[serial]
async fn the_crate_grants_a_posts_documents_to_its_owner() {
    request::<App, _, _>(|request, ctx| async move {
        let user = prepare_data::init_user_login(&request, &ctx).await;
        let (auth_key, auth_value) = prepare_data::auth_header(&user.token);

        let created = request
            .post("/api/posts")
            .add_header(auth_key.clone(), auth_value.clone())
            .json(&serde_json::json!({ "title": "Hello" }))
            .await;
        assert_eq!(created.status_code(), 201);
        let post = created.json::<serde_json::Value>();
        let (id, pid) = (
            post["id"].as_i64().unwrap(),
            post["pid"].as_str().unwrap().to_string(),
        );

        // loco-yrby serves the grant route; the app writes none.
        let path = format!("/yrby/grants/Post/{pid}/body");
        let res = request
            .get(&path)
            .add_header(auth_key.clone(), auth_value.clone())
            .await;
        assert_eq!(res.status_code(), 200);
        let grant = res.json::<serde_json::Value>()["grant"]
            .as_str()
            .unwrap()
            .to_string();
        // It names the post by its public id, never its row id.
        let payload = claims(&grant);
        assert_eq!(payload["sub"], format!("Post/{pid}"));
        assert_eq!(payload["name"], "body");
        assert_eq!(payload["aud"], "yrby");

        // The login token works from a cookie or the query too, as a page sends it.
        let cookie = format!("auth_token={}", user.token);
        let res = request
            .get(&path)
            .add_header(
                axum::http::header::COOKIE,
                axum::http::HeaderValue::from_str(&cookie).unwrap(),
            )
            .await;
        assert_eq!(res.status_code(), 200);
        let res = request.get(&format!("{path}?token={}", user.token)).await;
        assert_eq!(res.status_code(), 200);

        // Without a login: 401. Undeclared attributes, unknown posts, and
        // unregistered models: 404.
        assert_eq!(request.get(&path).await.status_code(), 401);
        for missing in [
            format!("/yrby/grants/Post/{pid}/title"),
            "/yrby/grants/Post/00000000-0000-0000-0000-000000000000/body".to_string(),
            format!("/yrby/grants/Post/{id}/body"),
            format!("/yrby/grants/Comment/{pid}/body"),
        ] {
            let res = request
                .get(&missing)
                .add_header(auth_key.clone(), auth_value.clone())
                .await;
            assert_eq!(res.status_code(), 404, "{missing}");
        }

        // Someone else's post: no grant, and no reading or changing it either.
        let bob = other_user_token(&request).await;
        let (bob_key, bob_value) = prepare_data::auth_header(&bob);
        for res in [
            request
                .get(&path)
                .add_header(bob_key.clone(), bob_value.clone())
                .await,
            request
                .get(&format!("/api/posts/{id}"))
                .add_header(bob_key.clone(), bob_value.clone())
                .await,
            request
                .delete(&format!("/api/posts/{id}"))
                .add_header(bob_key.clone(), bob_value.clone())
                .await,
        ] {
            assert_eq!(res.status_code(), 403);
        }
        let listed = request
            .get("/api/posts")
            .add_header(bob_key, bob_value)
            .await;
        assert_eq!(
            listed.json::<serde_json::Value>()["items"]
                .as_array()
                .map(Vec::len),
            Some(0)
        );
    })
    .await;
}

/// Register and log in a second user, returning their login token.
async fn other_user_token(request: &loco_rs::TestServer) -> String {
    let account =
        serde_json::json!({ "name": "Bob", "email": "bob@example.com", "password": "hunter22" });
    request.post("/api/auth/register").json(&account).await;
    let res = request
        .post("/api/auth/login")
        .json(&serde_json::json!({ "email": "bob@example.com", "password": "hunter22" }))
        .await;
    res.json::<serde_json::Value>()["token"]
        .as_str()
        .unwrap()
        .to_string()
}
