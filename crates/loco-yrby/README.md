# loco-yrby

Collaborative documents for [Loco](https://loco.rs) apps. Several people edit
the same document at once, in a browser editor such as Tiptap, and every
change is saved in the app's own database.

It is the Loco side of [yrby](https://github.com/jpcamara/yrby). The browser
runs the `yrby-client` package. [AnyCable](https://anycable.io)'s `anycable-go`
holds the WebSockets and calls the Loco app over gRPC. The app decides who may
open what and stores every change before anyone else sees it.

```text
browser (yrby-client) <-> anycable-go <-> gRPC <-> your Loco app <-> your database
```

What you get:

- Durable sync. A change is stored, then relayed to the other editors, then
  acknowledged to its author. Nothing lives only in memory, so the app can
  restart, or run on several machines, without losing an edit.
- yrby-rails' storage: the same two tables, the same compaction, and the same
  encryption format. A Rails app using yrby-rails and a Loco app using this
  crate can share one database.
- Grants and identity. A page receives a signed grant for one document, and
  the connection is identified as a user, so a per-user policy can decide at
  subscribe time.

## Install

### 1. The crate

```toml
[dependencies]
loco-yrby = "0.1"
```

### 2. The tables

Loco apps own their migrations. Add yrby's to your `Migrator`, then run
`cargo loco db migrate`:

```rust,ignore
// migration/src/lib.rs
fn migrations() -> Vec<Box<dyn MigrationTrait>> {
    vec![
        Box::new(m20220101_000001_users::Migration),
        Box::new(loco_yrby::migration::CreateYTables),
        // inject-above (do not remove this comment)
    ]
}
```

The crate has its own entities for these tables. Tell Loco not to generate
copies of them, in the app's `Cargo.toml`:

```toml
[package.metadata.db.entity]
ignore-tables = "y_documents,y_document_updates"
```

### 3. Which models have documents

Implement `Collaborative` on each model that backs documents. It plays the
part of yrby-rails' `has_collaborative_document`:

```rust,ignore
// src/models/posts.rs
#[async_trait::async_trait]
impl loco_yrby::Collaborative for Model {
    const RECORD_TYPE: &'static str = "Post";
    const DOCUMENTS: &'static [&'static str] = &["body", "notes"];
    const ENCRYPTED: &'static [&'static str] = &["body"];

    fn public_id(&self) -> String {
        self.pid.to_string()
    }

    fn record_id(&self) -> i64 {
        self.id
    }

    async fn locate(db: &DatabaseConnection, public_id: &str) -> Option<Self> {
        Self::find_by_pid(db, public_id).await.ok()
    }

    // Optional. Runs once per subscribe, with the connection's user.
    async fn authorize_document(
        &self,
        db: &DatabaseConnection,
        identity: &loco_yrby::Identity,
        _name: &str,
    ) -> bool {
        match loco_yrby::connected_user(identity) {
            // is_owned_by is the app's own check, on its model.
            Some(user_pid) => self.is_owned_by(db, user_pid).await,
            None => false,
        }
    }
}
```

`DOCUMENTS` lists the attributes that are documents. A grant for any other
name is refused. `ENCRYPTED` picks which of them are stored encrypted, once
encryption is configured. Grants name a record by its public id, so they
never expose row ids. A record that has been deleted opens nothing.

### 4. The initializer

```rust,ignore
// src/app.rs
async fn initializers(_ctx: &AppContext) -> Result<Vec<Box<dyn Initializer>>> {
    Ok(vec![Box::new(
        loco_yrby::YrbyInitializer::new().collaborative::<crate::models::posts::Model>(),
    )])
}
```

When the app starts its server, the initializer starts the gRPC service that
anycable-go calls. Workers and tasks don't start it. It stops on the same
signal as the web server.

### 5. Configuration

```yaml
# config/development.yaml
initializers:
  yrby:
    rpc_addr: 127.0.0.1:50051                       # anycable-go's --rpc_host
    broadcast_url: http://127.0.0.1:8080/_broadcast # anycable-go's HTTP broadcaster
    anycable_secret: <%= get_env(name="ANYCABLE_SECRET") %>     # anycable-go's --secret
    grant_secret: <%= get_env(name="YRBY_GRANT_SECRET") %>      # signs grants; a secret of its own
    compact_every: 64
    # Optional: encryption at rest, in Active Record encryption's format. Use
    # a Rails app's active_record.encryption values to share a database with it.
    encryption:
      primary_key: <%= get_env(name="AR_ENCRYPTION_PRIMARY_KEY", default="") %>
      key_derivation_salt: <%= get_env(name="AR_ENCRYPTION_KEY_DERIVATION_SALT", default="") %>
      hash_digest_class: SHA256   # SHA1 for Rails apps on load_defaults before 7.1
```

Other settings:

- `broadcast_key`: anycable-go's `--broadcast_key`, if it is set. Without it,
  the key is derived from `anycable_secret`, as anycable-go derives it.
- `anycable_jwt_secret`: anycable-go's `--jwt_secret`, if it differs from
  `--secret`.
- `login_cookie` (default `auth_token`): the cookie that holds the Loco login
  token, for connections that arrive without a connection token.
- `allow_anonymous` (default `false`): accept connections that no user is
  identified on.

anycable-go's gRPC calls carry no credentials, so keep `rpc_addr` on a private
address. `cargo loco doctor` checks the configuration and that the tables exist.

### 6. anycable-go

```sh
anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http --secret="$ANYCABLE_SECRET"
```

## Using it from a page

The app gives a page two tokens:

- A grant for each document it shows. `Yrby::from_context(&ctx)?.grant_for(&post, "body", ttl)`
  mints one. Check that the user may edit the post before minting it.
- A connection token, `Yrby::from_context(&ctx)?.connection_token(&user_pid, ttl)`.
  anycable-go verifies it and identifies the connection as that user, with no
  call to the app. Keep it short-lived; the client refreshes it.

```js
import { createConsumer } from "@anycable/web";
import { DocumentSessionStore } from "yrby-client";

const consumer = createConsumer(`wss://cable.example.com/cable?jid=${connectionToken}`, {
  // anycable-go refuses an expired token; fetch a new one and reconnect.
  tokenRefresher: async (transport) => transport.setParam("jid", await fetchConnectionToken()),
});
const lease = DocumentSessionStore.for(consumer).acquire({ grant, name: "body" });
// lease.session.doc is the Y.Doc to bind an editor to.
```

A connection without a token is identified by the Loco login cookie instead,
through anycable-go's connect call.

## Sharing a database with a Rails app

The tables, document keys (`post/42/body`), record binding, compaction, and
encryption are yrby-rails' own, so both apps can read and write the same
documents. Two things to line up:

- Encryption: configure the same `active_record.encryption` primary key, salt,
  and digest on both sides.
- Grants: Rails signs GlobalIDs by default. Set `config.yrby.grant_secret` to
  the same `grant_secret`, and `config.yrby.grant_format = :jwt`, and each app
  accepts the other's grants. Rails models that name records by a public id
  set `self.collaborative_public_id = :pid`.

`interop/run.sh` checks this against yrby-rails itself, in Docker.

## Example

[`examples/loco-demo`](../../examples/loco-demo) is a complete Loco app with
users, owned posts, grants, and connection tokens, and the end-to-end tests in
`packages/client/e2e` drive it with the real client.
