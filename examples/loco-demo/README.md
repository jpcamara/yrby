# loco-demo

A [Loco](https://loco.rs) app with collaborative documents, through
[`loco-yrby`](../../crates/loco-yrby). It began as `loco new` (SQLite,
in-process workers, no assets), and every yrby piece was added the way the
`loco-yrby` README describes.

What it shows:

- Users log in with Loco's JWT auth. Posts belong to their author.
- Each post has two collaborative documents, `body` and `notes`. The body is
  stored encrypted, the notes are not.
- `GET /api/posts/{id}/grant?name=body` gives the post's owner a grant for one
  of its documents. Anyone else gets a 403.
- `GET /api/cable/token` gives a logged-in user a short-lived token that
  identifies their WebSocket connection to anycable-go.
- Only the owner may open a post's documents, on a connection identified as
  them (`Collaborative::authorize_document` in `src/models/posts.rs`).

It is an API: there are no pages yet. The end-to-end tests in
[`packages/client/e2e`](../../packages/client/e2e) play the browser.

## Run it

```sh
export ANYCABLE_SECRET=dev-anycable-secret
anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http --secret="$ANYCABLE_SECRET" &
cargo loco start
```

The `initializers.yrby` block in `config/development.yaml` names the gRPC
address, the broadcast URL, and the secrets. To encrypt the body at rest, set
`AR_ENCRYPTION_PRIMARY_KEY` and `AR_ENCRYPTION_KEY_DERIVATION_SALT`.

## Tests

```sh
cargo test                          # the app's request and model tests
cd ../../packages/client && npm run build && node e2e/loco.mjs
```

## Working on it

The app is shaped by Loco's generators: `cargo loco generate scaffold posts`,
`generate migration AddUserRefToPosts user:references`, and
`generate controller cable`. `AGENTS.md` and `.claude/skills/loco` are Loco's
own guide for agents, as `loco new` writes them.
