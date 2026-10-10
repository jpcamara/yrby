# loco-yrby

Collaborative documents for [Loco](https://loco.rs) apps. Several people edit
the same document at once, in a browser editor such as Tiptap, and every
change is saved in the app's own database before anyone else sees it.

It is the Loco side of [yrby](https://github.com/jpcamara/yrby). The browser
runs the `yrby-client` package, which talks to the app over a WebSocket the
app serves itself.

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

That is all the server needs. When the app starts, it serves:

- `/yrby/cable`: the WebSocket the browser connects to. It speaks ActionCable's
  protocol, so the standard clients work.
- `/yrby/grants/Post/{pid}/body`: a grant to that document for the logged-in
  user, if `is_editable_by` allows it; 401, 403, or 404 otherwise.

Users are identified by the app's own login: the JWT from Loco's auth, read
from the `auth_token` cookie, a `?token=` query parameter, or a `Bearer`
header. Grants are signed with a key derived from the app's
`auth.jwt.secret`. There is nothing else to configure.

## The page

```js
import { createConsumer } from "@rails/actioncable"; // or @anycable/web
import { YrbyDocumentElement } from "yrby-client/element";

// A page with the login cookie can connect to "/yrby/cable" as is. An app that
// keeps the login token in the browser, as Loco's React starter does, passes it.
YrbyDocumentElement.consumer = createConsumer(`/yrby/cable?token=${loginToken}`);
```

```html
<yrby-document grant="…" name="body" refresh="/yrby/grants/Post/…/body"></yrby-document>
```

Fetch the grant from the grant route. `refresh` lets the element fetch a new
one by itself when it is refused. Or use `DocumentSessionStore` directly, as
the yrby-client README shows.

## Configuration

Everything is optional:

```yaml
# config/<env>.yaml
initializers:
  yrby:
    encryption_key: <%= get_env(name="YRBY_ENCRYPTION_KEY", default="") %>  # openssl rand -base64 32
```

- `encryption_key` encrypts the attributes declared `encrypted` at rest.
  `previous_encryption_keys` keeps older keys readable while you rotate.
  Documents written before encryption was on stay readable.
- `cable_path` (`/yrby/cable`), `routes_path` (`/yrby`), `grant_ttl` (a week;
  grants are re-checked against the model at every subscribe),
  `compact_every` (64), `login_cookie` (`auth_token`), `token_param`
  (`token`), `allow_anonymous` (`false`), `grant_secret` (derived).

`cargo loco doctor` checks the configuration and that the tables exist.

## Several app processes

The WebSocket's broadcasts stay inside the process that serves it, so every
browser editing a document must reach the same process. To run several,
put [AnyCable](https://anycable.io)'s `anycable-go` in front: it holds the
WebSockets and calls the app over gRPC, and broadcasts reach every process.

```yaml
initializers:
  yrby:
    transport: anycable
    anycable:
      rpc_addr: 127.0.0.1:50051                       # anycable-go's --rpc_host; keep it private
      broadcast_url: http://127.0.0.1:8080/_broadcast
      secret: <%= get_env(name="ANYCABLE_SECRET") %>  # anycable-go's --secret
```

```sh
anycable-go --rpc_host=127.0.0.1:50051 --broadcast_adapter=http --secret="$ANYCABLE_SECRET"
```

The page then connects to anycable-go with a connection token from
`/yrby/token`:

```js
import { createConsumer } from "@anycable/web";

const token = async () => (await (await fetch("/yrby/token")).json()).token;
const consumer = createConsumer(`wss://cable.example.com/cable?jid=${await token()}`, {
  tokenRefresher: async (transport) => transport.setParam("jid", await token()),
});
```

## Example

[`examples/loco-demo`](../../examples/loco-demo) is a complete Loco app with
users and owned posts, and the end-to-end tests in `packages/client/e2e` drive
it with the real client, in both transports.
