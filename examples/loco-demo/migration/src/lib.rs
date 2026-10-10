#![allow(elided_lifetimes_in_paths)]
#![allow(clippy::wildcard_imports)]
pub use sea_orm_migration::prelude::*;
mod m20220101_000001_users;

mod m20260930_145547_posts;
mod m20261008_142335_add_user_ref_to_posts;
pub struct Migrator;

#[async_trait::async_trait]
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20220101_000001_users::Migration),
            Box::new(loco_yrby::migration::CreateYTables),
            Box::new(m20260930_145547_posts::Migration),
            Box::new(m20261008_142335_add_user_ref_to_posts::Migration),
            // inject-above (do not remove this comment)
        ]
    }
}
