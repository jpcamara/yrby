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

// A post's body and notes are collaborative documents. The body is stored
// encrypted when the app sets an encryption key. Only the post's owner edits
// them.
loco_yrby::collaborative!(Model as "Post",
    documents: ["body", "notes"],
    encrypted: ["body"],
    authorize: is_owned_by,
);

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
