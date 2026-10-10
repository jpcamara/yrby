//! yrby collaborative documents for [Loco](https://loco.rs) apps, served
//! through [AnyCable](https://anycable.io).
//!
//! - [`YrbyInitializer`]: serves the document channel to anycable-go over gRPC,
//!   from the app's own process, with documents in the app's database.
//! - [`migration::CreateYTables`]: the tables, as yrby-rails defines them.
//! - [`SeaOrmStore`]: the store, with yrby-rails' compaction and optional
//!   encryption at rest ([`DocumentCipher`]).
//! - [`Collaborative`]: declare which models back documents, and how grants find them.
//! - [`Yrby::grant_for`]: mint the grants pages hand to `<yrby-document>`.
//!
//! The browser runs yrby-client with an AnyCable consumer, unchanged.

// README examples are living code: compile-checked on every cargo test.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
mod readme_examples {}

pub mod collaborative;
pub mod connection;
pub mod crypto;
pub mod entities;
mod initializer;
pub mod migration;
pub mod store;

pub use collaborative::{Collaborative, key_for};
pub use connection::{LoginCookie, connected_user};
pub use crypto::DocumentCipher;
pub use initializer::{Settings, Yrby, YrbyInitializer};
pub use store::SeaOrmStore;
/// Who a connection is, for [`Collaborative::authorize_document`].
pub use yrby_core::engine::Identity;
