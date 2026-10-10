use sea_orm::prelude::{DateTimeWithTimeZone, Uuid};
use ts_rs::TS;

#[derive(serde::Serialize, serde::Deserialize, TS)]
pub struct PostDto {
    #[ts(type = "number")]
    pub id: i64,
    pub title: String,
    #[ts(type = "string")]
    pub pid: Uuid,
    #[ts(type = "string")]
    pub created_at: DateTimeWithTimeZone,
    #[ts(type = "string")]
    pub updated_at: DateTimeWithTimeZone,
}

impl From<crate::models::_entities::posts::Model> for PostDto {
    fn from(m: crate::models::_entities::posts::Model) -> Self {
        Self {
            id: m.id,
            title: m.title,
            pid: m.pid,
            created_at: m.created_at,
            updated_at: m.updated_at,
        }
    }
}

#[derive(serde::Serialize, serde::Deserialize, TS)]
pub struct CreatePost {
    pub title: String,
}

#[derive(serde::Serialize, serde::Deserialize, TS)]
pub struct UpdatePost {
    pub title: String,
}

#[derive(serde::Serialize, serde::Deserialize, TS)]
pub struct GrantDto {
    pub grant: String,
}
