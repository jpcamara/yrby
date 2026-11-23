//! The two tables, as yrby-rails defines them.

/// `y_documents`: one row per document. `state` is the compacted snapshot.
pub mod documents {
    use sea_orm::entity::prelude::*;

    #[derive(Clone, Debug, PartialEq, Eq, DeriveEntityModel)]
    #[sea_orm(table_name = "y_documents")]
    pub struct Model {
        #[sea_orm(primary_key)]
        pub id: i64,
        /// What a channel addresses: one opaque, unique string, such as `post/42/body`.
        #[sea_orm(unique)]
        pub key: String,
        /// The record and attribute the document backs, when it backs one.
        pub record_type: Option<String>,
        pub record_id: Option<i64>,
        pub name: Option<String>,
        #[sea_orm(column_type = "Blob", nullable)]
        pub state: Option<Vec<u8>>,
        pub created_at: DateTime,
        pub updated_at: DateTime,
    }

    #[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
    pub enum Relation {}

    impl ActiveModelBehavior for ActiveModel {}
}

/// `y_document_updates`: the uncompacted tail, one CRDT delta per row.
pub mod updates {
    use sea_orm::entity::prelude::*;

    #[derive(Clone, Debug, PartialEq, Eq, DeriveEntityModel)]
    #[sea_orm(table_name = "y_document_updates")]
    pub struct Model {
        #[sea_orm(primary_key)]
        pub id: i64,
        pub document_id: i64,
        #[sea_orm(column_type = "Blob")]
        pub payload: Vec<u8>,
        /// Quarantined behind a causal gap, until its dependency arrives.
        pub pending: bool,
        pub created_at: DateTime,
    }

    #[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
    pub enum Relation {}

    impl ActiveModelBehavior for ActiveModel {}
}
