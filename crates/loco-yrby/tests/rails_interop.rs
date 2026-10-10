// A Rails app and a Loco app sharing one database: yrby-rails' own models
// (in Docker, see interop/) and loco-yrby's SeaOrmStore read, write, and
// compact the same documents, encrypted ones included.
//
// Needs Docker. crates/loco-yrby/interop/run.sh builds the image, starts
// Postgres, and runs every combination of:
//
// YRBY_INTEROP_DB=sqlite|postgres (Postgres at YRBY_INTEROP_PG_URL),
// YRBY_INTEROP_SCHEMA=rails|loco (whose migration creates the tables), and
// YRBY_INTEROP_DIGEST=SHA256|SHA1 (Active Record's key derivation digest).
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use loco_yrby::SeaOrmStore;
use loco_yrby::crypto::HashDigest;
use loco_yrby::migration::CreateYTables;
use sea_orm::{ConnectOptions, ConnectionTrait, Database, DatabaseConnection};
use sea_orm_migration::{MigrationTrait, MigratorTrait};
use serde_json::{Value, json};
use yrby_core::store::DocumentStore;
use yrs::updates::decoder::Decode;
use yrs::{Doc, GetString, Text, Transact, Update};

const PRIMARY_KEY: &str = "interop-primary-key-interop-primary-key";
const SALT: &str = "interop-key-derivation-salt-interop";
const COMPACT_EVERY: u64 = 4;

struct Migrator;
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![Box::new(CreateYTables)]
    }
}

/// The Rails side: a long-lived container with the repo and yrby built.
struct Rails {
    container: String,
    database_url: String,
    digest: String,
    shared: PathBuf,
}

impl Rails {
    fn start(shared: &Path, database_url: String, digest: &str) -> Self {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap();
        let container = format!("yrby-interop-{}", std::process::id());
        run(Command::new("docker")
            .args(["run", "-d", "--rm", "--name", &container])
            .args([
                "-v",
                &format!("{}:/src:ro", repo.display()),
                "-v",
                "yrby-interop-bundle:/bundle",
                "-v",
                "yrby-interop-cargo:/cargo-target",
                "-v",
                &format!("{}:/shared", shared.display()),
                "--add-host=host.docker.internal:host-gateway",
                "yrby-interop",
                "sleep",
                "infinity",
            ]));
        let rails = Self {
            container,
            database_url,
            digest: digest.to_string(),
            shared: shared.to_path_buf(),
        };
        // A copy of the repo, with pg for the Postgres runs, and the extension built.
        rails.sh(
            "rsync -a --delete --exclude target --exclude node_modules --exclude tmp --exclude examples \
             --exclude packages --exclude 'lib/y/*.bundle' /src/ /work/ \
             && cd /work && (grep -q '^gem \"pg\"' Gemfile || echo 'gem \"pg\"' >> Gemfile) \
             && bundle install --quiet && bundle exec rake compile > /dev/null",
        );
        rails
    }

    fn sh(&self, script: &str) -> String {
        run(Command::new("docker")
            .args(["exec", "-e", &format!("DATABASE_URL={}", self.database_url)])
            .args([
                "-e",
                &format!("AR_PRIMARY_KEY={PRIMARY_KEY}"),
                "-e",
                &format!("AR_KEY_DERIVATION_SALT={SALT}"),
            ])
            .args([
                "-e",
                &format!("AR_HASH_DIGEST={}", self.digest),
                "-e",
                &format!("COMPACT_EVERY={COMPACT_EVERY}"),
            ])
            .args([&self.container, "bash", "-c", script]))
    }

    fn call(&self, command: &str, docs: &Value) -> String {
        std::fs::write(self.shared.join("docs.json"), docs.to_string()).unwrap();
        self.sh(&format!(
            "cd /work && bundle exec ruby crates/loco-yrby/interop/rails_side.rb {command} /shared/docs.json"
        ))
    }
}

impl Drop for Rails {
    fn drop(&mut self) {
        let _ = Command::new("docker")
            .args(["rm", "-f", &self.container])
            .output();
    }
}

fn run(command: &mut Command) -> String {
    let output = command.output().expect("docker runs");
    assert!(
        output.status.success(),
        "{command:?} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

/// Successive edits by one client to the "content" text, each its own update.
fn edits(client: u64, prefix: &str, count: usize) -> Vec<Vec<u8>> {
    let doc = Doc::with_client_id(client);
    let text = doc.get_or_insert_text("content");
    (0..count)
        .map(|i| {
            let mut txn = doc.transact_mut();
            let len = text.len(&txn);
            text.insert(&mut txn, len, &format!("{prefix}{i} "));
            txn.encode_update_v1()
        })
        .collect()
}

fn text_of(updates: &[Vec<u8>]) -> String {
    let doc = Doc::new();
    for update in updates {
        doc.transact_mut()
            .apply_update(Update::decode_v1(update).unwrap())
            .unwrap();
    }
    let text = doc.get_or_insert_text("content");
    text.get_string(&doc.transact())
}

fn b64(updates: &[Vec<u8>]) -> Vec<String> {
    updates.iter().map(|u| STANDARD.encode(u)).collect()
}

async fn connect(url: &str) -> DatabaseConnection {
    let mut options = ConnectOptions::new(url);
    options.max_connections(1).sqlx_logging(false);
    Database::connect(options).await.unwrap()
}

#[tokio::test]
#[ignore = "needs Docker and the yrby-interop image"]
async fn rails_and_loco_share_a_database() {
    let backend = std::env::var("YRBY_INTEROP_DB").unwrap_or_else(|_| "sqlite".into());
    let schema = std::env::var("YRBY_INTEROP_SCHEMA").unwrap_or_else(|_| "rails".into());
    let digest = std::env::var("YRBY_INTEROP_DIGEST").unwrap_or_else(|_| "SHA256".into());
    let shared = tempfile::tempdir().unwrap();

    let (rails_url, loco_url) = if backend == "postgres" {
        // The server as this process reaches it; the container reaches the
        // same server through the Docker host.
        let server = std::env::var("YRBY_INTEROP_PG_URL")
            .unwrap_or_else(|_| "postgres://yrby:yrby@127.0.0.1:55432".into());
        let from_docker = server
            .replace("@127.0.0.1:", "@host.docker.internal:")
            .replace("@localhost:", "@host.docker.internal:");
        let name = format!("yrby_interop_{}", std::process::id());
        let admin = connect(&format!("{server}/postgres")).await;
        admin
            .execute_unprepared(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();
        (format!("{from_docker}/{name}"), format!("{server}/{name}"))
    } else {
        (
            "/shared/interop.sqlite".to_string(),
            format!(
                "sqlite://{}/interop.sqlite?mode=rwc",
                shared.path().display()
            ),
        )
    };
    let rails = Rails::start(shared.path(), rails_url, &digest);

    // Whoever owns the schema creates it; the other side uses it as is.
    if schema == "rails" {
        rails.call("migrate", &json!([]));
    } else {
        Migrator::up(&connect(&loco_url).await, None).await.unwrap();
    }

    let rails_body = edits(1, "rails-body-", 9);
    let rails_notes = edits(2, "rails-notes-", 5);
    let loco_body = edits(3, "loco-body-", 9);
    let loco_notes = edits(4, "loco-notes-", 5);
    let loco_on_rails_body = edits(5, "loco-on-rails-", 6);

    // 1. Rails writes (and, every four appends, compacts) its documents.
    rails.call(
        "append",
        &json!([
            { "key": "post/1/body", "encrypted": true, "updates": b64(&rails_body) },
            { "key": "post/1/notes", "encrypted": false, "updates": b64(&rails_notes) },
        ]),
    );

    // 2. Loco reads them, and writes its own; and adds to Rails' document,
    //    compacting over rows Rails wrote.
    let digest_class = if digest == "SHA1" {
        HashDigest::SHA1
    } else {
        HashDigest::SHA256
    };
    let cipher =
        loco_yrby::DocumentCipher::new(&[PRIMARY_KEY.to_string()], SALT, digest_class).unwrap();
    let encrypts: loco_yrby::store::EncryptionPolicy = Arc::new(|key: &str| key.ends_with("/body"));
    let open_store = || {
        let (cipher, encrypts, url) = (cipher.clone(), encrypts.clone(), loco_url.clone());
        async move {
            let db = connect(&url).await;
            let store = SeaOrmStore::new(db.clone())
                .compact_every(COMPACT_EVERY)
                .encryption(cipher)
                .encrypt_documents(encrypts);
            (db, store)
        }
    };
    let load = |store: SeaOrmStore, key: &'static str| async move {
        text_of(&[store.load(key).await.unwrap().expect(key)])
    };
    let (db, store) = open_store().await;
    assert_eq!(
        load(store.clone(), "post/1/body").await,
        text_of(&rails_body),
        "Loco reads Rails' encrypted document"
    );
    assert_eq!(
        load(store.clone(), "post/1/notes").await,
        text_of(&rails_notes),
        "Loco reads Rails' plain document"
    );
    for (key, updates) in [
        ("post/2/body", &loco_body),
        ("post/2/notes", &loco_notes),
        ("post/1/body", &loco_on_rails_body),
    ] {
        for update in updates {
            store.append(key, update).await.unwrap();
        }
    }
    // Hand the database over: closing the pool checkpoints SQLite's WAL into
    // the file. The file is shared with a Linux VM, where WAL's shared memory
    // is not, so Rails would otherwise miss the newest writes.
    drop(store);
    db.close().await.unwrap();
    let expected = json!({
        "post/1/body": text_of(&[rails_body.clone(), loco_on_rails_body.clone()].concat()),
        "post/1/notes": text_of(&rails_notes),
        "post/2/body": text_of(&loco_body),
        "post/2/notes": text_of(&loco_notes),
    });

    // 3. Rails reads everything, compacts everything, and reads it again.
    let docs = json!([
        { "key": "post/1/body", "encrypted": true },
        { "key": "post/1/notes", "encrypted": false },
        { "key": "post/2/body", "encrypted": true },
        { "key": "post/2/notes", "encrypted": false },
    ]);
    let read = |rails: &Rails| serde_json::from_str::<Value>(&rails.call("read", &docs)).unwrap();
    assert_eq!(read(&rails), expected, "Rails reads what Loco wrote");
    let inspected: Value = serde_json::from_str(&rails.call("inspect", &docs)).unwrap();
    for key in ["post/1/body", "post/2/body"] {
        assert_eq!(
            inspected[key]["plain_values"], 0,
            "{key}: every value encrypted, by Rails' own check"
        );
    }
    for key in ["post/1/notes", "post/2/notes"] {
        assert_eq!(inspected[key]["encrypted_values"], 0, "{key}: stored plain");
    }
    rails.call("compact", &docs);
    assert_eq!(
        read(&rails),
        expected,
        "Rails compacts Loco's rows without losing anything"
    );

    // 4. And Loco reads Rails' compactions.
    let (_db, store) = open_store().await;
    for key in ["post/1/body", "post/1/notes", "post/2/body", "post/2/notes"] {
        assert_eq!(
            load(store.clone(), key).await,
            expected[key],
            "Loco reads {key} after Rails compacted it"
        );
    }
}
