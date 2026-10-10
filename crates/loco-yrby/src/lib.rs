//! Collaborative documents for [Loco](https://loco.rs) apps, with
//! [yrby](https://github.com/jpcamara/yrby).
//!
//! - [`YrbyInitializer`]: serves the documents from the app itself: an
//!   ActionCable endpoint for yrby-client, and a route that hands out grants.
//!   AnyCable is an option for running several app processes.
//! - [`collaborative!`]: declares which of a model's attributes are documents,
//!   and the model method that decides who may edit them.
//! - [`migration::CreateYTables`]: the tables.
//! - [`SeaOrmStore`]: the store: a snapshot plus a log of updates, compacted,
//!   and optionally encrypted at rest ([`DocumentCipher`]).

// README examples are living code: compile-checked on every cargo test.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
mod readme_examples {}

pub mod cable;
pub mod collaborative;
pub mod connection;
pub mod crypto;
pub mod entities;
mod initializer;
pub mod migration;
pub mod store;

pub use collaborative::{Collaborative, key_for};
pub use connection::{LocoLogin, connected_user};
pub use crypto::DocumentCipher;
pub use initializer::{AnyCableSettings, Settings, Transport, Yrby, YrbyInitializer};
pub use store::SeaOrmStore;
/// Who a connection is, for [`Collaborative::authorize_document`].
pub use yrby_core::engine::Identity;

#[doc(hidden)]
pub use async_trait::async_trait as __async_trait;
#[doc(hidden)]
pub use sea_orm as __sea_orm;

/// Make a Loco model's attributes collaborative documents.
///
/// ```ignore
/// loco_yrby::collaborative!(Model as "Post",
///     documents: ["body", "notes"],
///     encrypted: ["body"],
///     authorize: is_editable_by,
/// );
///
/// impl Model {
///     pub async fn is_editable_by(&self, db: &DatabaseConnection, user_pid: &str) -> bool {
///         // your rule
///     }
/// }
/// ```
///
/// It assumes Loco's conventions: the model has `id: i64` and a `pid: Uuid`
/// column, and grants name records by `pid`. `authorize` names a method on
/// the model that decides whether a logged-in user may edit its documents.
/// Connections without a user are refused before it is asked. It is
/// required, so a model is never editable by everyone by accident. For
/// anything else, implement [`Collaborative`] yourself.
#[macro_export]
macro_rules! collaborative {
    (
        $model:ty as $record_type:literal,
        documents: [$($document:literal),+ $(,)?],
        $(encrypted: [$($encrypted:literal),* $(,)?],)?
        authorize: $policy:ident $(,)?
    ) => {
        #[$crate::__async_trait]
        impl $crate::Collaborative for $model {
            const RECORD_TYPE: &'static str = $record_type;
            const DOCUMENTS: &'static [&'static str] = &[$($document),+];
            const ENCRYPTED: &'static [&'static str] = &[$($($encrypted),*)?];

            fn public_id(&self) -> ::std::string::String {
                self.pid.to_string()
            }

            fn record_id(&self) -> i64 {
                self.id
            }

            async fn locate(
                db: &$crate::__sea_orm::DatabaseConnection,
                public_id: &str,
            ) -> ::std::option::Option<Self> {
                use $crate::__sea_orm::{EntityTrait, ModelTrait, QueryFilter};
                use $crate::__sea_orm::sea_query::{Alias, Expr, ExprTrait};
                let pid = $crate::__sea_orm::prelude::Uuid::parse_str(public_id).ok()?;
                <<Self as ModelTrait>::Entity as EntityTrait>::find()
                    .filter(Expr::col(Alias::new("pid")).eq(pid))
                    .one(db)
                    .await
                    .ok()
                    .flatten()
            }

            async fn authorize_document(
                &self,
                db: &$crate::__sea_orm::DatabaseConnection,
                identity: &$crate::Identity,
                _name: &str,
            ) -> bool {
                match $crate::connected_user(identity) {
                    ::std::option::Option::Some(user) => self.$policy(db, user).await,
                    ::std::option::Option::None => false,
                }
            }
        }
    };
}
