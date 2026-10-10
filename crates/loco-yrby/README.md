# loco-yrby

Collaborative documents for [Loco](https://loco.rs) apps. Several people edit
the same document at once, in a browser editor such as Tiptap, and every
change is saved in the app's own database before anyone else sees it.

It is the Loco side of [yrby](https://github.com/jpcamara/yrby). The browser
runs the `yrby-client` package, connected to
[AnyCable](https://anycable.io)'s `anycable-go`, which holds the WebSockets
and calls the app over gRPC. Every app process serves the same documents, so
you can run as many as you like.

What you get:

- Durable sync. A change is stored, then relayed to the other editors, then
  acknowledged to its author. Nothing lives only in memory.
- Storage in two tables of your database: a snapshot plus a log of updates,
  compacted as it grows, without losing an update that is still waiting on
  another. Optionally encrypted at rest, per attribute.
- Access control on your models: a method on the model decides who may edit
  its documents, checked whenever a page asks for access and again whenever
  a browser opens the document.

## Install

### 1. The crate

```toml
[dependencies]
loco-yrby = "0.1"
```

### 2. The tables

Loco apps own their migrations, so add yrby's to your `Migrator`, then run
`cargo loco db migrate`:

```rust,ignore
// migration/src/lib.rs
Box::new(loco_yrby::migration::CreateYTables),
```

The crate has its own entities for these tables. To keep `cargo loco db
entities` from generating copies, add to the app's `Cargo.toml`:

```toml
[package.metadata.db.entity]
ignore-tables = "y_documents,y_document_updates"
```

### 3. The model

Say which attributes are documents, and which model method decides who may
edit them:

```rust,ignore
// src/models/posts.rs
loco_yrby::collaborative!(Model as "Post",
    documents: ["body", "notes"],
    encrypted: ["body"],
    authorize: is_editable_by,
);

impl Model {
    pub async fn is_editable_by(&self, db: &DatabaseConnection, user_pid: &str) -> bool {
        // your rule, for example: the post belongs to this user
    }
}
```

The macro assumes Loco's conventions: an `id` and a `pid` column. A record
that has been deleted opens nothing. For other shapes, implement the
`Collaborative` trait instead.

### 4. The initializer

```rust,ignore
// src/app.rs
async fn initializers(_ctx: &AppContext) -> Result<Vec<Box<dyn Initializer>>> {
    Ok(vec![Box::new(
        loco_yrby::YrbyInitializer::new().collaborative::<crate::models::posts::Model>(),
    )])
}
```

### 5. anycable-go

Tell the app the secret anycable-go runs with:

```yaml
# config/<env>.yaml
initializers:
  yrby:
    anycable:
      secret: <%= get_env(name="ANYCABLE_SECRET") %>  # anycable-go's --secret
```

```sh
anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http --secret="$ANYCABLE_SECRET"
```

When the app starts its web server, it serves:

- AnyCable's gRPC service on `127.0.0.1:50051`, for anycable-go. anycable-go
  sends no credentials over gRPC, so keep it on a private address.
- `/yrby/grants/Post/{pid}/body`: a grant to that document for the logged-in
  user, if `is_editable_by` allows it; 401, 403, or 404 otherwise.
- `/yrby/token`: a token that identifies the logged-in user's connection to
  anycable-go, so it needs no call to the app.

Users are identified by the app's own login: the JWT from Loco's auth, read
from the `auth_token` cookie or a `Bearer` header. Grants are signed with a
key derived from the app's `auth.jwt.secret`.

## The page

```js
import { createConsumer } from "@anycable/web";
import { YrbyDocumentElement } from "yrby-client/element";

// /yrby/token reads the login cookie. An app that keeps the login token in
// the browser, as Loco's React starter does, sends it as a Bearer header.
const token = async () => (await (await fetch("/yrby/token")).json()).token;
YrbyDocumentElement.consumer = createConsumer(`wss://cable.example.com/cable?jid=${await token()}`, {
  tokenRefresher: async (transport) => transport.setParam("jid", await token()),
});
```

```html
<yrby-document grant="…" name="body" refresh="/yrby/grants/Post/…/body"></yrby-document>
```

Fetch the grant from the grant route. `refresh` lets the element fetch a new
one by itself when it is refused. Or use `DocumentSessionStore` directly, as
the yrby-client README shows.

## Configuration

Beyond `anycable.secret`, everything is optional:

```yaml
# config/<env>.yaml
initializers:
  yrby:
    encryption_key: <%= get_env(name="YRBY_ENCRYPTION_KEY", default="") %>  # openssl rand -base64 32
    anycable:
      secret: <%= get_env(name="ANYCABLE_SECRET") %>
      rpc_addr: 127.0.0.1:50051                        # anycable-go's --rpc_host
      broadcast_url: http://127.0.0.1:8080/_broadcast
```

- `encryption_key` encrypts the attributes declared `encrypted` at rest.
  `previous_encryption_keys` keeps older keys readable while you rotate.
  Documents written before encryption was on stay readable.
- `routes_path` (`/yrby`), `grant_ttl` (a week; grants are re-checked
  against the model at every subscribe), `compact_every` (64),
  `login_cookie` (`auth_token`), `token_param` (`token`), `allow_anonymous`
  (`false`), `grant_secret` (derived).
- `anycable`: `broadcast_key` (anycable-go's `--broadcast_key`, if it has
  one; otherwise derived from `secret`), `jwt_secret` (its `--jwt_secret`, if
  that differs from `secret`), `token_ttl` (300 seconds; the client refreshes
  the token).

`cargo loco doctor` checks the configuration and that the tables exist.

## Example

[`examples/loco-demo`](../../examples/loco-demo) is a complete Loco app with
users and owned posts, and the end-to-end tests in `packages/client/e2e` drive
it with the real client through anycable-go.
