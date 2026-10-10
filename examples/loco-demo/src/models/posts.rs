pub use super::_entities::posts::{ActiveModel, Entity, Model};
use loco_rs::prelude::*;
use sea_orm::entity::prelude::*;
pub type Posts = Entity;

#[async_trait::async_trait]
impl ActiveModelBehavior for ActiveModel {
    async fn before_save<C>(self, _db: &C, insert: bool) -> std::result::Result<Self, DbErr>
    where
        C: ConnectionTrait,
    {
        let mut this = self;
        if insert && this.pid.is_not_set() {
            // The public id grants carry, so they never expose row ids.
            this.pid = sea_orm::ActiveValue::Set(Uuid::new_v4());
        }
        if !insert && this.updated_at.is_unchanged() {
            this.updated_at = sea_orm::ActiveValue::Set(chrono::Utc::now().into());
        }
        Ok(this)
    }
}

/// A post's `body` and `notes` are collaborative documents; the body is
/// stored encrypted when the app configures encryption.
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

    /// Only the post's owner edits its body, on a connection identified as them.
    async fn authorize_document(
        &self,
        db: &DatabaseConnection,
        identity: &loco_yrby::Identity,
        _name: &str,
    ) -> bool {
        match loco_yrby::connected_user(identity) {
            Some(user_pid) => self.is_owned_by(db, user_pid).await,
            None => false,
        }
    }
}

// implement your read-oriented logic here
impl Model {
    /// Whether the user with this pid owns the post.
    pub async fn is_owned_by(&self, db: &DatabaseConnection, user_pid: &str) -> bool {
        super::users::Model::find_by_pid(db, user_pid)
            .await
            .is_ok_and(|user| user.id == self.user_id)
    }

    /// # Errors
    /// `ModelError::EntityNotFound` when no post has this pid, or it is not a UUID.
    pub async fn find_by_pid(db: &DatabaseConnection, pid: &str) -> ModelResult<Self> {
        let pid = Uuid::parse_str(pid).map_err(|_| ModelError::EntityNotFound)?;
        Entity::find()
            .filter(
                model::query::condition()
                    .eq(super::_entities::posts::Column::Pid, pid)
                    .build(),
            )
            .one(db)
            .await?
            .ok_or(ModelError::EntityNotFound)
    }
}

// implement your write-oriented logic here
impl ActiveModel {}

// implement your custom finders, selectors oriented logic here
impl Entity {}
