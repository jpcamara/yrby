//! yrby's sync and storage rules for Yjs documents, as plain Rust.
//!
//! [yrby](https://github.com/jpcamara/yrby) keeps collaborative documents on a
//! server that stores every change before anyone else sees it. This crate is
//! the part of it that does not depend on any framework or transport. The
//! Ruby gem's native extension uses it, and so do yrby's Rust servers.
//!
//! - [`protocol`]: reading y-protocols frames. It classifies a frame, merges
//!   the updates it carries, and decides exactly whether an update can apply
//!   now or is waiting on a dependency, and whether it adds anything new.
//! - [`compaction`]: storing a document as a snapshot plus a log of updates.
//!   It merges them on load and plans compactions that fold the log into the
//!   snapshot without losing an update that is still waiting on a dependency.
//!
//! With the `engine` feature:
//!
//! - [`engine`]: the server's sync loop, for any transport. It opens a
//!   document for a grant, answers a client's sync request from the store,
//!   and stores each change, then relays it, then acknowledges it.
//! - [`grant`] and [`store`]: signed, expiring grants that say which document
//!   a page may open, and the interface a document store implements.

// README examples are living code: compile-checked on every cargo test.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
mod readme_examples {}

pub mod compaction;
pub mod protocol;

#[cfg(feature = "engine")]
pub mod engine;
#[cfg(feature = "engine")]
pub mod grant;
#[cfg(feature = "engine")]
pub mod store;

pub use yrs;
