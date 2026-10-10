//! A [`DocumentStore`] on SeaORM: yrby-rails' storage, in the app's database.

use std::sync::Arc;

use async_trait::async_trait;
use sea_orm::sea_query::OnConflict;
use sea_orm::{
    ActiveValue::Set, ColumnTrait, DatabaseBackend, DatabaseConnection, EntityTrait,
    PaginatorTrait, QueryFilter, QueryOrder, QuerySelect, TransactionTrait,
};
use yrby_core::compaction::{self, CompactionPlan};
use yrby_core::store::{DocumentStore, StoreError};

use crate::crypto::{self, DocumentCipher};
use crate::entities::{documents, updates};

/// How many clean tail rows trigger a compaction, as in yrby-rails.
pub const DEFAULT_COMPACT_EVERY: u64 = 64;

/// Documents in `y_documents` and `y_document_updates`.
///
/// An append inserts one tail row. Once a document has `compact_every` clean
/// (non-pending) rows, the append also compacts: it folds the tail into the
/// snapshot under a row lock and deletes what it folded. Rows behind a causal
/// gap stay, marked pending, and do not count toward the threshold.
#[derive(Clone)]
pub struct SeaOrmStore {
    db: DatabaseConnection,
    compact_every: u64,
    cipher: Option<DocumentCipher>,
    encrypts: Option<EncryptionPolicy>,
}

/// Which documents a store encrypts, by key.
pub type EncryptionPolicy = Arc<dyn Fn(&str) -> bool + Send + Sync>;

fn now() -> chrono::NaiveDateTime {
    chrono::Utc::now().naive_utc()
}

impl SeaOrmStore {
    pub fn new(db: DatabaseConnection) -> Self {
        Self {
            db,
            compact_every: DEFAULT_COMPACT_EVERY,
            cipher: None,
            encrypts: None,
        }
    }

    /// Encrypt document state and updates at rest. Values written before
    /// encryption was on stay readable; see [`DocumentCipher`].
    pub fn encryption(mut self, cipher: DocumentCipher) -> Self {
        self.cipher = Some(cipher);
        self
    }

    /// Encrypt only the documents `policy` picks, by key, as yrby-rails
    /// encrypts only attributes declared `encrypted: true`. Without a policy,
    /// a store with a cipher encrypts every document. Reading never needs the
    /// policy: an encrypted value says so.
    pub fn encrypt_documents(mut self, policy: EncryptionPolicy) -> Self {
        self.encrypts = Some(policy);
        self
    }

    /// The cipher to write `key`'s values with, if it is encrypted.
    fn sealer(&self, key: &str) -> Option<DocumentCipher> {
        let cipher = self.cipher.as_ref()?;
        self.encrypts
            .as_ref()
            .is_none_or(|encrypts| encrypts(key))
            .then(|| cipher.clone())
    }

    pub fn compact_every(mut self, rows: u64) -> Self {
        self.compact_every = rows.max(1);
        self
    }

    async fn document_id(&self, key: &str) -> Result<Option<i64>, StoreError> {
        Ok(documents::Entity::find()
            .select_only()
            .column(documents::Column::Id)
            .filter(documents::Column::Key.eq(key))
            .into_tuple::<i64>()
            .one(&self.db)
            .await?)
    }

    /// The document's id, inserting a key-only row on first use. Two racing
    /// first appends both insert; the unique key makes one a no-op.
    async fn document_id_or_create(&self, key: &str) -> Result<i64, StoreError> {
        if let Some(id) = self.document_id(key).await? {
            return Ok(id);
        }
        let row = documents::ActiveModel {
            key: Set(key.to_string()),
            created_at: Set(now()),
            updated_at: Set(now()),
            ..Default::default()
        };
        documents::Entity::insert(row)
            .on_conflict(
                OnConflict::column(documents::Column::Key)
                    .do_nothing()
                    .to_owned(),
            )
            .exec_without_returning(&self.db)
            .await?;
        self.document_id(key)
            .await?
            .ok_or_else(|| format!("document {key:?} vanished after insert").into())
    }

    /// Make sure the document `key` exists and records which attribute of which
    /// record it backs, as yrby-rails' `Y::Document.for` does. A key-only row
    /// (written before any binding existed) is adopted rather than duplicated.
    pub async fn bind(
        &self,
        key: &str,
        record_type: &str,
        record_id: i64,
        name: &str,
    ) -> Result<(), StoreError> {
        let existing = documents::Entity::find()
            .select_only()
            .column(documents::Column::RecordType)
            .filter(documents::Column::Key.eq(key))
            .into_tuple::<Option<String>>()
            .one(&self.db)
            .await?;
        match existing {
            Some(Some(_)) => Ok(()),
            Some(None) => {
                documents::Entity::update_many()
                    .col_expr(documents::Column::RecordType, record_type.into())
                    .col_expr(documents::Column::RecordId, record_id.into())
                    .col_expr(documents::Column::Name, name.into())
                    .col_expr(documents::Column::UpdatedAt, now().into())
                    .filter(documents::Column::Key.eq(key))
                    .filter(documents::Column::RecordType.is_null())
                    .exec(&self.db)
                    .await?;
                Ok(())
            }
            None => {
                let row = documents::ActiveModel {
                    key: Set(key.to_string()),
                    record_type: Set(Some(record_type.to_string())),
                    record_id: Set(Some(record_id)),
                    name: Set(Some(name.to_string())),
                    created_at: Set(now()),
                    updated_at: Set(now()),
                    ..Default::default()
                };
                documents::Entity::insert(row)
                    .on_conflict(
                        OnConflict::column(documents::Column::Key)
                            .do_nothing()
                            .to_owned(),
                    )
                    .exec_without_returning(&self.db)
                    .await?;
                Ok(())
            }
        }
    }

    /// Fold the document's tail into its snapshot. Safe to run concurrently
    /// with appends: a row that lands mid-compaction is not in the plan, so it
    /// survives and compacts next time.
    pub async fn compact(&self, document_id: i64) -> Result<(), StoreError> {
        let txn = self.db.begin().await?;
        // Serialize racing compactions on the document row. SQLite has no row
        // locks; its write lock serializes the transactions instead.
        let mut query = documents::Entity::find_by_id(document_id)
            .select_only()
            .column(documents::Column::Key)
            .column(documents::Column::State);
        if self.db.get_database_backend() != DatabaseBackend::Sqlite {
            query = query.lock_exclusive();
        }
        let Some((key, state)) = query
            .into_tuple::<(String, Option<Vec<u8>>)>()
            .one(&txn)
            .await?
        else {
            return Ok(());
        };
        let rows: Vec<(i64, Vec<u8>)> = updates::Entity::find()
            .select_only()
            .column(updates::Column::Id)
            .column(updates::Column::Payload)
            .filter(updates::Column::DocumentId.eq(document_id))
            .order_by_asc(updates::Column::Id)
            .into_tuple()
            .all(&txn)
            .await?;
        if rows.is_empty() {
            return Ok(());
        }

        let (cipher, sealer) = (self.cipher.clone(), self.sealer(&key));
        let CompactionPlan {
            state: new_state,
            delete,
            quarantine,
        } = tokio::task::spawn_blocking(move || {
            let cipher = cipher.as_ref();
            let state = state.map(|s| crypto::open(cipher, &key, s)).transpose()?;
            let rows = rows
                .into_iter()
                .map(|(id, payload)| Ok((id, crypto::open(cipher, &key, payload)?)))
                .collect::<Result<Vec<_>, StoreError>>()?;
            let mut plan = compaction::plan(state.as_deref(), &rows)?;
            if let Some(sealer) = sealer {
                plan.state = plan.state.map(|s| sealer.encrypt(&s));
            }
            Ok::<_, StoreError>(plan)
        })
        .await??;

        if let Some(new_state) = new_state {
            documents::Entity::update_many()
                .col_expr(documents::Column::State, new_state.into())
                .col_expr(documents::Column::UpdatedAt, now().into())
                .filter(documents::Column::Id.eq(document_id))
                .exec(&txn)
                .await?;
        }
        if !delete.is_empty() {
            updates::Entity::delete_many()
                .filter(updates::Column::Id.is_in(delete))
                .exec(&txn)
                .await?;
        }
        if !quarantine.is_empty() {
            updates::Entity::update_many()
                .col_expr(updates::Column::Pending, true.into())
                .filter(updates::Column::Id.is_in(quarantine))
                .exec(&txn)
                .await?;
        }
        txn.commit().await?;
        Ok(())
    }
}

#[async_trait]
impl DocumentStore for SeaOrmStore {
    async fn load(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let Some(id) = self.document_id(key).await? else {
            return Ok(None);
        };
        // Tail first, then the snapshot: see compaction::merged_state.
        let tail: Vec<Vec<u8>> = updates::Entity::find()
            .select_only()
            .column(updates::Column::Payload)
            .filter(updates::Column::DocumentId.eq(id))
            .order_by_asc(updates::Column::Id)
            .into_tuple()
            .all(&self.db)
            .await?;
        let state: Option<Vec<u8>> = documents::Entity::find_by_id(id)
            .select_only()
            .column(documents::Column::State)
            .into_tuple::<Option<Vec<u8>>>()
            .one(&self.db)
            .await?
            .flatten();
        let (cipher, key) = (self.cipher.clone(), key.to_string());
        tokio::task::spawn_blocking(move || {
            let cipher = cipher.as_ref();
            let state = state.map(|s| crypto::open(cipher, &key, s)).transpose()?;
            let tail = tail
                .into_iter()
                .map(|p| crypto::open(cipher, &key, p))
                .collect::<Result<Vec<_>, _>>()?;
            compaction::merged_state(state.as_deref(), &tail)
        })
        .await?
    }

    async fn append(&self, key: &str, update: &[u8]) -> Result<(), StoreError> {
        let id = self.document_id_or_create(key).await?;
        let row = updates::ActiveModel {
            document_id: Set(id),
            payload: Set(match self.sealer(key) {
                Some(sealer) => sealer.encrypt(update),
                None => update.to_vec(),
            }),
            pending: Set(false),
            created_at: Set(now()),
            ..Default::default()
        };
        updates::Entity::insert(row)
            .exec_without_returning(&self.db)
            .await?;

        // The trigger is at-or-over (concurrent appends can jump past it) and
        // counts clean rows only, so a quarantined gap does not retrigger it.
        let clean = updates::Entity::find()
            .filter(updates::Column::DocumentId.eq(id))
            .filter(updates::Column::Pending.eq(false))
            .count(&self.db)
            .await?;
        if clean >= self.compact_every {
            // The update is already durable, so the append has succeeded. A
            // failed compaction only leaves the tail longer; the next append
            // over the threshold tries again.
            if let Err(error) = self.compact(id).await {
                tracing::warn!(key, %error, "[yrby] compaction failed; will retry on a later append");
            }
        }
        Ok(())
    }
}
