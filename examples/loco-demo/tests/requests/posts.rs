use loco_rs::testing::prelude::*;
use serial_test::serial;
use yrby_loco::app::App;

use super::prepare_data;

// The test config's initializers.yrby.grant_secret.
const GRANT_SECRET: &str = "yrby-test-grant-secret";

#[tokio::test]
#[serial]
async fn grants_a_posts_body_document() {
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

        let res = request
            .get(&format!("/api/posts/{id}/grant?name=body"))
            .add_header(auth_key.clone(), auth_value.clone())
            .await;
        assert_eq!(res.status_code(), 200);
        let grant = res.json::<serde_json::Value>()["grant"]
            .as_str()
            .unwrap()
            .to_string();
        // The grant names the post by its public id, never its row id.
        let signer = yrby_anycable::GrantSigner::new(GRANT_SECRET);
        assert_eq!(signer.verify(&grant, "body"), Some(format!("Post/{pid}")));
        assert_eq!(signer.verify(&grant, "title"), None);

        // Only declared documents can be granted.
        let res = request
            .get(&format!("/api/posts/{id}/grant?name=title"))
            .add_header(auth_key.clone(), auth_value.clone())
            .await;
        assert_eq!(res.status_code(), 400);

        let res = request
            .get("/api/posts/999999/grant?name=body")
            .add_header(auth_key, auth_value)
            .await;
        assert_eq!(res.status_code(), 404);

        // Someone else's post: no grant, and no reading or changing it either.
        let bob = other_user_token(&request).await;
        let (bob_key, bob_value) = prepare_data::auth_header(&bob);
        for res in [
            request
                .get(&format!("/api/posts/{id}/grant?name=body"))
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

#[tokio::test]
#[serial]
async fn grants_require_a_login() {
    request::<App, _, _>(|request, _ctx| async move {
        let res = request.get("/api/posts/1/grant?name=body").await;
        assert_eq!(res.status_code(), 401);
    })
    .await;
}
