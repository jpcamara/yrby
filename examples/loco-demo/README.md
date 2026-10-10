# loco-demo

A [Loco](https://loco.rs) app with collaborative documents, through
[`loco-yrby`](../../crates/loco-yrby). It began as `loco new` (SQLite,
in-process workers, no assets), and every yrby piece was added the way the
`loco-yrby` README describes: a migration line, a model macro, and an
initializer.

What it shows:

- Users log in with Loco's JWT auth. Posts belong to their author.
- Each post has two collaborative documents, `body` and `notes`, declared in
  `src/models/posts.rs`. The body is stored encrypted when an encryption key
  is set; the notes are not.
- Only a post's owner may edit its documents (`is_owned_by`, on the model).
- The app serves the WebSocket at `/yrby/cable` and grants at
  `/yrby/grants/Post/{pid}/{name}`. There are no yrby controllers in the app.

It is an API: there are no pages yet. The end-to-end tests in
[`packages/client/e2e`](../../packages/client/e2e) play the browser.

## Run it

```sh
cargo loco start
```

`YRBY_ENCRYPTION_KEY` (`openssl rand -base64 32`) turns on encryption.
`YRBY_TRANSPORT=anycable` runs behind anycable-go instead; see the
`initializers.yrby` block in `config/development.yaml`.

## Tests

```sh
cargo test                          # the app's request and model tests
cd ../../packages/client && npm run build && node e2e/loco.mjs
```

## Working on it

The app is shaped by Loco's generators: `cargo loco generate scaffold posts`
and `generate migration AddUserRefToPosts user:references`. `AGENTS.md` and
`.claude/skills/loco` are Loco's own guide for agents, as `loco new` writes
them.
