// SeaOrmStore against a real SQLite database, migrated with CreateYTables.
use loco_yrby::SeaOrmStore;
use loco_yrby::entities::{documents, updates};
use loco_yrby::migration::CreateYTables;
use std::sync::atomic::{AtomicU64, Ordering};

use sea_orm::{
    ColumnTrait, ConnectOptions, ConnectionTrait, Database, DatabaseConnection, EntityTrait,
    PaginatorTrait, QueryFilter,
};
use sea_orm_migration::{MigrationTrait, MigratorTrait};
use yrby_core::store::DocumentStore;
use yrs::updates::decoder::Decode;
use yrs::{Doc, GetString, ReadTxn, Text, Transact, Update};

struct Migrator;
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![Box::new(CreateYTables)]
    }
}

/// A fresh, migrated database: Postgres when `YRBY_TEST_POSTGRES_URL` points
/// at a server (each test gets a database of its own), SQLite otherwise.
async fn database(connections: u32) -> (DatabaseConnection, TestDb) {
    if let Ok(admin_url) = std::env::var("YRBY_TEST_POSTGRES_URL") {
        let name = format!(
            "yrby_test_{}",
            std::process::id() as u64 * 1_000_000 + COUNTER.fetch_add(1, Ordering::SeqCst)
        );
        let admin = Database::connect(&admin_url).await.unwrap();
        admin
            .execute_unprepared(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();
        let url = format!(
            "{}/{name}",
            admin_url.trim_end_matches('/').rsplit_once('/').unwrap().0
        );
        let mut options = ConnectOptions::new(url);
        options.max_connections(connections).sqlx_logging(false);
        let db = Database::connect(options).await.unwrap();
        Migrator::up(&db, None).await.unwrap();
        return (db, TestDb::Postgres);
    }
    let dir = tempfile::tempdir().unwrap();
    let url = format!(
        "sqlite://{}?mode=rwc",
        dir.path().join("yrby.sqlite").display()
    );
    let mut options = ConnectOptions::new(url);
    options.max_connections(connections).sqlx_logging(false);
    let db = Database::connect(options).await.unwrap();
    Migrator::up(&db, None).await.unwrap();
    (db, TestDb::Sqlite(dir))
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// Keeps a SQLite file alive for the test. Postgres test databases are left
/// for the server's owner to drop; they are named yrby_test_*.
#[allow(dead_code)]
enum TestDb {
    Sqlite(tempfile::TempDir),
    Postgres,
}

/// Successive edits by one client, each as its own update.
fn edits(client: u64, parts: &[&str]) -> Vec<Vec<u8>> {
    let doc = Doc::with_client_id(client);
    let text = doc.get_or_insert_text("t");
    parts
        .iter()
        .map(|part| {
            let mut txn = doc.transact_mut();
            let len = text.len(&txn);
            text.insert(&mut txn, len, part);
            txn.encode_update_v1()
        })
        .collect()
}

fn text(state: &[u8]) -> String {
    let doc = Doc::new();
    doc.transact_mut()
        .apply_update(Update::decode_v1(state).unwrap())
        .unwrap();
    let text = doc.get_or_insert_text("t");
    text.get_string(&doc.transact())
}

fn has_pending(state: &[u8]) -> bool {
    let doc = Doc::new();
    doc.transact_mut()
        .apply_update(Update::decode_v1(state).unwrap())
        .unwrap();
    let txn = doc.transact();
    txn.store().pending_update().is_some() || txn.store().pending_ds().is_some()
}

async fn rows(db: &DatabaseConnection, key: &str) -> (u64, u64, bool) {
    let doc = documents::Entity::find()
        .filter(documents::Column::Key.eq(key))
        .one(db)
        .await
        .unwrap()
        .unwrap();
    let count = |pending: bool| {
        updates::Entity::find()
            .filter(updates::Column::DocumentId.eq(doc.id))
            .filter(updates::Column::Pending.eq(pending))
            .count(db)
    };
    (
        count(false).await.unwrap(),
        count(true).await.unwrap(),
        doc.state.is_some(),
    )
}

#[tokio::test]
async fn appends_and_loads() {
    let (db, _dir) = database(1).await;
    let store = SeaOrmStore::new(db.clone());
    assert_eq!(store.load("post/1/body").await.unwrap(), None);

    for update in edits(1, &["hello", ", ", "world"]) {
        store.append("post/1/body", &update).await.unwrap();
    }
    let state = store.load("post/1/body").await.unwrap().unwrap();
    assert_eq!(text(&state), "hello, world");
    assert_eq!(
        rows(&db, "post/1/body").await,
        (3, 0, false),
        "below the threshold: tail only"
    );
    assert_eq!(
        store.load("post/2/body").await.unwrap(),
        None,
        "documents are separate"
    );
}

#[tokio::test]
async fn compacts_the_tail_into_the_snapshot_at_the_threshold() {
    let (db, _dir) = database(1).await;
    let store = SeaOrmStore::new(db.clone()).compact_every(4);
    let updates = edits(1, &["a", "b", "c", "d", "e", "f"]);

    for update in &updates[..4] {
        store.append("doc", update).await.unwrap();
    }
    assert_eq!(
        rows(&db, "doc").await,
        (0, 0, true),
        "the fourth append compacted everything"
    );
    assert_eq!(text(&store.load("doc").await.unwrap().unwrap()), "abcd");

    for update in &updates[4..] {
        store.append("doc", update).await.unwrap();
    }
    assert_eq!(
        rows(&db, "doc").await,
        (2, 0, true),
        "snapshot plus a new tail"
    );
    assert_eq!(text(&store.load("doc").await.unwrap().unwrap()), "abcdef");
}

#[tokio::test]
async fn tolerates_duplicate_appends() {
    let (db, _dir) = database(1).await;
    let store = SeaOrmStore::new(db).compact_every(3);
    let update = &edits(1, &["once"])[0];
    // A lost ack makes the client send the same update again.
    for _ in 0..5 {
        store.append("doc", update).await.unwrap();
    }
    assert_eq!(text(&store.load("doc").await.unwrap().unwrap()), "once");
}

#[tokio::test]
async fn quarantines_a_gap_and_heals_it_when_the_dependency_arrives() {
    let (db, _dir) = database(1).await;
    let store = SeaOrmStore::new(db.clone()).compact_every(2);
    let x = edits(1, &["x1", "x2"]); // x2 depends on x1
    let y = edits(2, &["y1", "y2", "y3"]);

    // x2 arrives without x1: a causal gap.
    store.append("doc", &x[1]).await.unwrap();
    store.append("doc", &y[0]).await.unwrap(); // second clean row: compacts
    assert_eq!(
        rows(&db, "doc").await,
        (0, 1, true),
        "y1 folded, x2 quarantined"
    );
    let served = store.load("doc").await.unwrap().unwrap();
    assert_eq!(text(&served), "y1", "the gapped edit stays invisible");
    assert!(
        has_pending(&served),
        "but travels to clients as pending, to heal there"
    );

    // Pending rows do not count toward the threshold.
    store.append("doc", &y[1]).await.unwrap();
    assert_eq!(rows(&db, "doc").await, (1, 1, true));

    // x1 arrives: the next compaction folds everything.
    store.append("doc", &x[0]).await.unwrap();
    assert_eq!(
        rows(&db, "doc").await,
        (0, 0, true),
        "the gap healed and nothing is left"
    );
    let healed = store.load("doc").await.unwrap().unwrap();
    assert!(!has_pending(&healed));
    let content = text(&healed);
    assert!(
        content.contains("x1x2") && content.contains("y1y2"),
        "{content}"
    );

    store.append("doc", &y[2]).await.unwrap();
    assert!(text(&store.load("doc").await.unwrap().unwrap()).contains("y1y2y3"));
}

#[tokio::test]
async fn concurrent_appends_lose_nothing() {
    let (db, _dir) = database(4).await;
    let store = SeaOrmStore::new(db.clone()).compact_every(8);
    let clients: Vec<Vec<Vec<u8>>> = (1..=8)
        .map(|client| {
            let parts: Vec<String> = (0..25).map(|i| format!("[{client}:{i}]")).collect();
            edits(
                client,
                &parts.iter().map(String::as_str).collect::<Vec<_>>(),
            )
        })
        .collect();

    // Each client appends its edits in order, all clients at once.
    let tasks: Vec<_> = clients
        .into_iter()
        .map(|updates| {
            let store = store.clone();
            tokio::spawn(async move {
                for update in updates {
                    store.append("doc", &update).await.unwrap();
                }
            })
        })
        .collect();
    for task in tasks {
        task.await.unwrap();
    }

    let content = text(&store.load("doc").await.unwrap().unwrap());
    for client in 1..=8 {
        for i in 0..25 {
            assert!(
                content.contains(&format!("[{client}:{i}]")),
                "lost [{client}:{i}]"
            );
        }
    }
    let (clean, pending, snapshot) = rows(&db, "doc").await;
    assert!(snapshot, "compaction ran");
    assert_eq!(pending, 0);
    assert!(clean < 200, "the tail was compacted ({clean} rows left)");
}

#[tokio::test]
async fn the_migration_rolls_back() {
    let (db, _dir) = database(1).await;
    Migrator::down(&db, None).await.unwrap();
    assert!(
        documents::Entity::find().one(&db).await.is_err(),
        "tables are gone"
    );
    Migrator::up(&db, None).await.unwrap();
}

#[tokio::test]
async fn racing_compactions_lose_nothing() {
    // Compact on every append, from eight writers at once: compactions
    // constantly overlap each other and the appends landing during them.
    let (db, _db) = database(8).await;
    let store = SeaOrmStore::new(db.clone()).compact_every(1);
    let tasks: Vec<_> = (1..=8u64)
        .map(|client| {
            let store = store.clone();
            let parts: Vec<String> = (0..30).map(|i| format!("<{client}.{i}>")).collect();
            let updates = edits(
                client,
                &parts.iter().map(String::as_str).collect::<Vec<_>>(),
            );
            tokio::spawn(async move {
                for update in updates {
                    store.append("race", &update).await.unwrap();
                }
            })
        })
        .collect();
    for task in tasks {
        task.await.unwrap();
    }
    // One last compaction folds whatever a failed (retryable) one left behind.
    let id = documents::Entity::find()
        .filter(documents::Column::Key.eq("race"))
        .one(&db)
        .await
        .unwrap()
        .unwrap()
        .id;
    store.compact(id).await.unwrap();

    let content = text(&store.load("race").await.unwrap().unwrap());
    let lost: Vec<String> = (1..=8)
        .flat_map(|c| (0..30).map(move |i| format!("<{c}.{i}>")))
        .filter(|edit| !content.contains(edit.as_str()))
        .collect();
    assert!(
        lost.is_empty(),
        "lost {} edits: {:?}",
        lost.len(),
        &lost[..lost.len().min(5)]
    );
    assert_eq!(rows(&db, "race").await, (0, 0, true));
}

fn cipher() -> loco_yrby::DocumentCipher {
    loco_yrby::DocumentCipher::new(
        &["primary".into()],
        "salt",
        loco_yrby::crypto::HashDigest::SHA256,
    )
    .unwrap()
}

async fn raw_values(db: &DatabaseConnection, key: &str) -> Vec<Vec<u8>> {
    let doc = documents::Entity::find()
        .filter(documents::Column::Key.eq(key))
        .one(db)
        .await
        .unwrap()
        .unwrap();
    let mut values: Vec<Vec<u8>> = doc.state.into_iter().collect();
    for row in updates::Entity::find()
        .filter(updates::Column::DocumentId.eq(doc.id))
        .all(db)
        .await
        .unwrap()
    {
        values.push(row.payload);
    }
    values
}

#[tokio::test]
async fn encrypts_state_and_updates_at_rest() {
    let (db, _db) = database(1).await;
    let store = SeaOrmStore::new(db.clone())
        .compact_every(4)
        .encryption(cipher());
    for update in edits(1, &["top ", "secret ", "plans ", "here", "!"]) {
        store.append("doc", &update).await.unwrap();
    }
    // Four appends compacted into the snapshot; the fifth is in the tail.
    assert_eq!(rows(&db, "doc").await, (1, 0, true));
    assert_eq!(
        text(&store.load("doc").await.unwrap().unwrap()),
        "top secret plans here!"
    );
    for value in raw_values(&db, "doc").await {
        assert!(
            loco_yrby::crypto::is_encrypted(&value),
            "stored unencrypted"
        );
        assert!(
            !value.windows(6).any(|w| w == b"secret"),
            "plaintext on disk"
        );
    }
    // Without the key, the store refuses rather than serving ciphertext.
    assert!(SeaOrmStore::new(db.clone()).load("doc").await.is_err());
}

#[tokio::test]
async fn turns_encryption_on_for_existing_documents() {
    let (db, _db) = database(1).await;
    let plain = SeaOrmStore::new(db.clone());
    let updates = edits(1, &["written ", "before ", "encryption, ", "then after"]);
    for update in &updates[..3] {
        plain.append("doc", update).await.unwrap();
    }
    let encrypted = SeaOrmStore::new(db.clone())
        .compact_every(4)
        .encryption(cipher());
    assert_eq!(
        text(&encrypted.load("doc").await.unwrap().unwrap()),
        "written before encryption, "
    );
    // The fourth append compacts plaintext and encrypted rows into an encrypted snapshot.
    encrypted.append("doc", &updates[3]).await.unwrap();
    assert_eq!(rows(&db, "doc").await, (0, 0, true));
    assert!(
        raw_values(&db, "doc")
            .await
            .iter()
            .all(|v| loco_yrby::crypto::is_encrypted(v))
    );
    assert_eq!(
        text(&encrypted.load("doc").await.unwrap().unwrap()),
        "written before encryption, then after"
    );
}

#[tokio::test]
async fn encrypts_only_the_documents_the_policy_picks() {
    let (db, _db) = database(1).await;
    let policy: loco_yrby::store::EncryptionPolicy =
        std::sync::Arc::new(|key: &str| key.ends_with("/body"));
    let store = SeaOrmStore::new(db.clone())
        .compact_every(2)
        .encryption(cipher())
        .encrypt_documents(policy);
    for key in ["post/1/body", "post/1/notes"] {
        for update in edits(1, &["one ", "two ", "three"]) {
            store.append(key, &update).await.unwrap();
        }
        assert_eq!(
            text(&store.load(key).await.unwrap().unwrap()),
            "one two three"
        );
    }
    assert!(
        raw_values(&db, "post/1/body")
            .await
            .iter()
            .all(|v| loco_yrby::crypto::is_encrypted(v))
    );
    assert!(
        raw_values(&db, "post/1/notes")
            .await
            .iter()
            .all(|v| !loco_yrby::crypto::is_encrypted(v))
    );
}
