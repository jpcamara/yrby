//! Records that back collaborative documents, and the grants that open them.
//!
//! This is yrby-rails' `has_collaborative_document` plus the GlobalID
//! locator, which Rust has no reflection for. A model says which record type
//! it is, which attributes are collaborative, and how to find a record by its
//! public id. The initializer's registry then turns a grant back into a record
//! (`Post/<pid>` → the post), checks the record still exists and the attribute
//! is one the model declared, and opens the document for that attribute.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use async_trait::async_trait;
use sea_orm::DatabaseConnection;
use yrby_core::engine::{DocumentAuthorizer, Identity};
use yrby_core::grant::GrantSigner;

use crate::store::SeaOrmStore;

/// A model whose attributes can be collaborative documents.
///
/// ```ignore
/// #[async_trait]
/// impl loco_yrby::Collaborative for posts::Model {
///     const RECORD_TYPE: &'static str = "Post";
///     const DOCUMENTS: &'static [&'static str] = &["body"];
///
///     fn public_id(&self) -> String { self.pid.to_string() }
///     fn record_id(&self) -> i64 { self.id }
///     async fn locate(db: &DatabaseConnection, public_id: &str) -> Option<Self> {
///         Self::find_by_pid(db, public_id).await.ok()
///     }
/// }
/// ```
#[async_trait]
pub trait Collaborative: Sized + Send + Sync + 'static {
    /// The record type, as Rails would write it to `record_type` (`"Post"`,
    /// `"Admin::Post"`). Grants and document keys are built from it.
    const RECORD_TYPE: &'static str;

    /// The attributes that are collaborative documents, such as `["body"]`.
    /// A grant for any other name is refused.
    const DOCUMENTS: &'static [&'static str];

    /// The documents stored encrypted, a subset of [`Self::DOCUMENTS`]: yrby-rails'
    /// `has_collaborative_document :body, encrypted: true`. Takes effect when
    /// the initializer has `encryption` configured.
    const ENCRYPTED: &'static [&'static str] = &[];

    /// The id grants carry. Use the model's public id (Loco's `pid`), not
    /// its primary key, so grants do not expose or enumerate row ids.
    fn public_id(&self) -> String;

    /// The primary key, for the document key (`post/42/body`) and the
    /// `record_id` column.
    fn record_id(&self) -> i64;

    /// The record with this public id, or `None` if there is none (a deleted
    /// record's grant then opens nothing).
    async fn locate(db: &DatabaseConnection, public_id: &str) -> Option<Self>;

    /// Whether this connection may open this record's `name` document, checked
    /// once at subscribe. The grant already says the page was allowed to; use
    /// this to re-check the current user, [`crate::connected_user`].
    async fn authorize_document(
        &self,
        _db: &DatabaseConnection,
        _identity: &Identity,
        _name: &str,
    ) -> bool {
        true
    }
}

/// The document key for one attribute of one record, as yrby-rails builds it
/// (`record_type.underscore/id/name`): `key_for("Post", 42, "body")` is
/// `post/42/body`, and `key_for("Admin::BlogPost", 7, "body")` is
/// `admin/blog_post/7/body`.
pub fn key_for(record_type: &str, record_id: i64, name: &str) -> String {
    format!("{}/{record_id}/{name}", underscore(record_type))
}

// ActiveSupport's String#underscore, for the class names it will see.
fn underscore(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 4);
    for (i, segment) in name.split("::").enumerate() {
        if i > 0 {
            out.push('/');
        }
        let chars: Vec<char> = segment.chars().collect();
        for (j, &c) in chars.iter().enumerate() {
            if c.is_uppercase() {
                let after_lower =
                    j > 0 && (chars[j - 1].is_lowercase() || chars[j - 1].is_ascii_digit());
                let acronym_end = j > 0
                    && chars[j - 1].is_uppercase()
                    && chars.get(j + 1).is_some_and(|n| n.is_lowercase());
                if after_lower || acronym_end {
                    out.push('_');
                }
                out.extend(c.to_lowercase());
            } else {
                out.push(c);
            }
        }
    }
    out
}

/// The grant subject for a record: `<RecordType>/<public id>`.
pub(crate) fn subject_for<T: Collaborative>(record: &T) -> String {
    format!("{}/{}", T::RECORD_TYPE, record.public_id())
}

/// What a request for a record's document comes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Resolved {
    /// The record exists and its policy allows this identity: its id.
    Allowed(i64),
    /// No such record type, attribute, or record.
    Missing,
    /// The record's policy refused this identity.
    Refused,
}

type Resolve = Arc<
    dyn Fn(
            DatabaseConnection,
            String,
            Identity,
            String,
        ) -> Pin<Box<dyn Future<Output = Resolved> + Send>>
        + Send
        + Sync,
>;

#[derive(Clone)]
struct Entry {
    documents: &'static [&'static str],
    encrypted: &'static [&'static str],
    resolve: Resolve,
}

/// The collaborative models an app registered, by record type.
#[derive(Clone, Default)]
pub(crate) struct Registry {
    entries: HashMap<&'static str, Entry>,
}

impl Registry {
    pub(crate) fn register<T: Collaborative>(&mut self) {
        let resolve: Resolve = Arc::new(|db, public_id, identity, name| {
            Box::pin(async move {
                let Some(record) = T::locate(&db, &public_id).await else {
                    return Resolved::Missing;
                };
                if record.authorize_document(&db, &identity, &name).await {
                    Resolved::Allowed(record.record_id())
                } else {
                    Resolved::Refused
                }
            })
        });
        self.entries.insert(
            T::RECORD_TYPE,
            Entry {
                documents: T::DOCUMENTS,
                encrypted: T::ENCRYPTED,
                resolve,
            },
        );
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Look up `record_type`'s record `public_id` and run its policy for
    /// `identity` on its `name` document.
    pub(crate) async fn resolve(
        &self,
        db: &DatabaseConnection,
        identity: &Identity,
        record_type: &str,
        public_id: &str,
        name: &str,
    ) -> Resolved {
        let Some(entry) = self.entries.get(record_type) else {
            return Resolved::Missing;
        };
        if !entry.documents.contains(&name) {
            return Resolved::Missing;
        }
        (entry.resolve)(
            db.clone(),
            public_id.to_string(),
            identity.clone(),
            name.to_string(),
        )
        .await
    }

    /// Whether a document key (`post/42/body`) names an attribute its model
    /// declares encrypted. Keys are `<underscored record type>/<id>/<name>`.
    pub(crate) fn encryption_policy(&self) -> crate::store::EncryptionPolicy {
        let encrypted: HashMap<String, &'static [&'static str]> = self
            .entries
            .iter()
            .map(|(record_type, entry)| (underscore(record_type), entry.encrypted))
            .collect();
        Arc::new(move |key: &str| {
            let Some((rest, name)) = key.rsplit_once('/') else {
                return false;
            };
            let Some((record_type, _id)) = rest.rsplit_once('/') else {
                return false;
            };
            encrypted
                .get(record_type)
                .is_some_and(|names| names.contains(&name))
        })
    }
}

/// Grants resolved through the registry: the document authorizer the
/// initializer installs.
pub(crate) struct RecordAuthorizer {
    pub(crate) signer: GrantSigner,
    pub(crate) registry: Registry,
    pub(crate) store: SeaOrmStore,
    pub(crate) db: DatabaseConnection,
}

#[async_trait]
impl DocumentAuthorizer for RecordAuthorizer {
    async fn authorize(&self, identity: &Identity, grant: &str, name: &str) -> Option<String> {
        let subject = self.signer.verify(grant, name)?;
        let (record_type, public_id) = subject.rsplit_once('/')?;
        let resolved = self
            .registry
            .resolve(&self.db, identity, record_type, public_id, name)
            .await;
        let Resolved::Allowed(record_id) = resolved else {
            tracing::info!(record_type, name, ?resolved, "[yrby] grant refused");
            return None;
        };
        let key = key_for(record_type, record_id, name);
        if let Err(error) = self.store.bind(&key, record_type, record_id, name).await {
            tracing::error!(key, %error, "[yrby] could not bind the document to its record");
            return None;
        }
        Some(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    use crate::entities::documents;
    use crate::initializer::Yrby;
    use crate::migration::CreateYTables;
    use sea_orm::{ColumnTrait, Database, EntityTrait, QueryFilter};
    use sea_orm_migration::{MigrationTrait, MigratorTrait};
    use serde_json::{Map, Value};
    use yrby_core::store::DocumentStore;

    // A stand-in model: records live in a map the test can delete from.
    static POSTS: Mutex<Vec<(i64, String)>> = Mutex::new(Vec::new());
    static REFUSE: Mutex<bool> = Mutex::new(false);

    #[derive(Debug)]
    struct Post {
        id: i64,
        pid: String,
    }

    #[async_trait]
    impl Collaborative for Post {
        const RECORD_TYPE: &'static str = "Post";
        const DOCUMENTS: &'static [&'static str] = &["body"];
        fn public_id(&self) -> String {
            self.pid.clone()
        }
        fn record_id(&self) -> i64 {
            self.id
        }
        async fn locate(_db: &DatabaseConnection, public_id: &str) -> Option<Self> {
            let posts = POSTS.lock().unwrap();
            posts
                .iter()
                .find(|(_, pid)| pid == public_id)
                .map(|(id, pid)| Post {
                    id: *id,
                    pid: pid.clone(),
                })
        }
        async fn authorize_document(
            &self,
            _db: &DatabaseConnection,
            identity: &Identity,
            _name: &str,
        ) -> bool {
            !*REFUSE.lock().unwrap() && identity.get("user") != Some("mallory")
        }
    }

    struct Migrator;
    impl MigratorTrait for Migrator {
        fn migrations() -> Vec<Box<dyn MigrationTrait>> {
            vec![Box::new(CreateYTables)]
        }
    }

    fn ctx(user: &str) -> Identity {
        Identity::new(serde_json::json!({ "user": user }))
    }

    async fn setup() -> (RecordAuthorizer, Yrby, DatabaseConnection) {
        *POSTS.lock().unwrap() = vec![(1, "pid-1".into()), (2, "pid-2".into())];
        *REFUSE.lock().unwrap() = false;
        let db = Database::connect("sqlite::memory:").await.unwrap();
        Migrator::up(&db, None).await.unwrap();
        let mut registry = Registry::default();
        registry.register::<Post>();
        let signer = GrantSigner::new("grant-secret");
        let authorizer = RecordAuthorizer {
            signer: signer.clone(),
            registry,
            store: SeaOrmStore::new(db.clone()),
            db: db.clone(),
        };
        (authorizer, Yrby::new(signer), db)
    }

    fn post(id: i64) -> Post {
        Post {
            id,
            pid: format!("pid-{id}"),
        }
    }

    // One test, run in order: the stand-in model is process-global.
    #[tokio::test]
    async fn grants_resolve_through_the_registry() {
        let (authorizer, yrby, db) = setup().await;

        // A grant for a live record opens that record's document and binds it.
        let grant = yrby.grant_for(&post(1), "body").unwrap();
        assert_eq!(
            authorizer
                .authorize(&ctx("ada"), &grant, "body")
                .await
                .as_deref(),
            Some("post/1/body")
        );
        let row = documents::Entity::find()
            .filter(documents::Column::Key.eq("post/1/body"))
            .one(&db)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                row.record_type.as_deref(),
                row.record_id,
                row.name.as_deref()
            ),
            (Some("Post"), Some(1), Some("body"))
        );

        // Undeclared attributes: refused when minting, and when presented.
        assert!(yrby.grant_for(&post(1), "title").is_err());
        let title = authorizer.signer.sign("Post/pid-1", "title", 60);
        assert_eq!(
            authorizer.authorize(&ctx("ada"), &title, "title").await,
            None
        );

        // Unregistered record types and unknown records open nothing.
        let comment = authorizer.signer.sign("Comment/pid-1", "body", 60);
        assert_eq!(
            authorizer.authorize(&ctx("ada"), &comment, "body").await,
            None
        );
        let ghost = authorizer.signer.sign("Post/pid-404", "body", 60);
        assert_eq!(
            authorizer.authorize(&ctx("ada"), &ghost, "body").await,
            None
        );

        // A deleted record's grant stops working, as a Rails sgid does.
        let grant2 = yrby.grant_for(&post(2), "body").unwrap();
        POSTS.lock().unwrap().retain(|(id, _)| *id != 2);
        assert_eq!(
            authorizer.authorize(&ctx("ada"), &grant2, "body").await,
            None
        );

        // The model's policy sees the connection.
        assert_eq!(
            authorizer.authorize(&ctx("mallory"), &grant, "body").await,
            None
        );
        *REFUSE.lock().unwrap() = true;
        assert_eq!(
            authorizer.authorize(&ctx("ada"), &grant, "body").await,
            None
        );
        *REFUSE.lock().unwrap() = false;

        // A key-only row written before any binding is adopted, not duplicated.
        let store = SeaOrmStore::new(db.clone());
        POSTS.lock().unwrap().push((3, "pid-3".into()));
        store.append("post/3/body", &[0, 0]).await.unwrap();
        let grant3 = yrby.grant_for(&post(3), "body").unwrap();
        assert_eq!(
            authorizer
                .authorize(&ctx("ada"), &grant3, "body")
                .await
                .as_deref(),
            Some("post/3/body")
        );
        let rows = documents::Entity::find()
            .filter(documents::Column::Key.eq("post/3/body"))
            .all(&db)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].record_type.as_deref(), Some("Post"));
    }

    #[test]
    fn loco_login_tokens_reject_a_yrby_grant() {
        // Even if an app signed grants with its login secret by mistake, Loco's
        // JWT validator would refuse a grant: it carries an audience Loco does
        // not expect. Loco decodes its secret as base64, so share the key bytes.
        use base64::Engine;
        let secret = "grant-and-login-secret";
        let loco_secret = base64::engine::general_purpose::STANDARD.encode(secret);
        let grant = GrantSigner::new(secret).sign("Post/pid-1", "body", 60);
        let loco = loco_rs::auth::jwt::JWT::new(&loco_secret);
        assert!(loco.validate(&grant).is_err());
        // The audience alone is what refuses it: the same claims plus a `pid`
        // validate as a login until `aud: "yrby"` is added.
        let exp = jsonwebtoken::get_current_timestamp() + 60;
        let key = jsonwebtoken::EncodingKey::from_secret(secret.as_bytes());
        let header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS512);
        let login_shaped =
            serde_json::json!({ "pid": "pid-1", "sub": "Post/pid-1", "name": "body", "exp": exp });
        assert!(
            loco.validate(&jsonwebtoken::encode(&header, &login_shaped, &key).unwrap())
                .is_ok()
        );
        let with_aud = serde_json::json!({ "pid": "pid-1", "aud": "yrby", "sub": "Post/pid-1", "name": "body", "exp": exp });
        assert!(
            loco.validate(&jsonwebtoken::encode(&header, &with_aud, &key).unwrap())
                .is_err()
        );

        // And a Loco login token is not a grant.
        let login = loco
            .generate_token(60, "pid-1".into(), Map::<String, Value>::new())
            .unwrap();
        assert_eq!(GrantSigner::new(secret).verify(&login, "body"), None);
    }

    #[test]
    fn encrypts_only_declared_attributes() {
        struct Note;
        #[async_trait]
        impl Collaborative for Note {
            const RECORD_TYPE: &'static str = "Admin::Note";
            const DOCUMENTS: &'static [&'static str] = &["body", "summary"];
            const ENCRYPTED: &'static [&'static str] = &["body"];
            fn public_id(&self) -> String {
                String::new()
            }
            fn record_id(&self) -> i64 {
                0
            }
            async fn locate(_: &DatabaseConnection, _: &str) -> Option<Self> {
                None
            }
        }
        let mut registry = Registry::default();
        registry.register::<Post>();
        registry.register::<Note>();
        let encrypts = registry.encryption_policy();
        assert!(encrypts("admin/note/7/body"));
        assert!(!encrypts("admin/note/7/summary"));
        assert!(!encrypts("post/1/body"), "Post declares nothing encrypted");
        assert!(!encrypts("room-42"));
        assert!(!encrypts("comment/1/body"));
    }

    #[test]
    fn keys_match_rails() {
        assert_eq!(key_for("Post", 42, "body"), "post/42/body");
        assert_eq!(key_for("BlogPost", 1, "body"), "blog_post/1/body");
        assert_eq!(key_for("Admin::Post", 7, "notes"), "admin/post/7/notes");
        assert_eq!(key_for("HTMLPage", 3, "body"), "html_page/3/body");
        assert_eq!(key_for("Post2Draft", 5, "body"), "post2_draft/5/body");
    }
}
