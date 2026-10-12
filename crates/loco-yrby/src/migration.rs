//! The migration for yrby's tables. Loco apps own their migration crate, so
//! add it to your `Migrator`:
//!
//! ```ignore
//! fn migrations() -> Vec<Box<dyn MigrationTrait>> {
//!     vec![
//!         Box::new(m20220101_000001_users::Migration),
//!         Box::new(loco_yrby::migration::CreateYTables),
//!     ]
//! }
//! ```
//!
//! The schema matches yrby-rails' `create_y_tables` migration.

use sea_orm_migration::prelude::*;

pub struct CreateYTables;

impl MigrationName for CreateYTables {
    fn name(&self) -> &str {
        "m20260929_000001_create_y_tables"
    }
}

#[async_trait::async_trait]
impl MigrationTrait for CreateYTables {
    async fn up(&self, m: &SchemaManager) -> Result<(), DbErr> {
        let documents = Alias::new("y_documents");
        let updates = Alias::new("y_document_updates");
        m.create_table(
            Table::create()
                .table(documents.clone())
                .col(
                    ColumnDef::new(Alias::new("id"))
                        .big_integer()
                        .not_null()
                        .auto_increment()
                        .primary_key(),
                )
                .col(ColumnDef::new(Alias::new("key")).string().not_null())
                .col(ColumnDef::new(Alias::new("record_type")).string().null())
                .col(ColumnDef::new(Alias::new("record_id")).big_integer().null())
                .col(ColumnDef::new(Alias::new("name")).string().null())
                .col(ColumnDef::new(Alias::new("state")).blob().null())
                .col(
                    ColumnDef::new(Alias::new("created_at"))
                        .timestamp()
                        .not_null(),
                )
                .col(
                    ColumnDef::new(Alias::new("updated_at"))
                        .timestamp()
                        .not_null(),
                )
                .to_owned(),
        )
        .await?;
        m.create_index(
            Index::create()
                .name("index_y_documents_on_key")
                .table(documents.clone())
                .col(Alias::new("key"))
                .unique()
                .to_owned(),
        )
        .await?;
        // Partial, as in Rails: key-only documents have no record.
        m.get_connection()
            .execute_unprepared(
                "CREATE UNIQUE INDEX index_y_documents_on_record_and_name \
                 ON y_documents (record_type, record_id, name) WHERE record_type IS NOT NULL",
            )
            .await?;

        m.create_table(
            Table::create()
                .table(updates.clone())
                .col(
                    ColumnDef::new(Alias::new("id"))
                        .big_integer()
                        .not_null()
                        .auto_increment()
                        .primary_key(),
                )
                .col(
                    ColumnDef::new(Alias::new("document_id"))
                        .big_integer()
                        .not_null(),
                )
                .col(ColumnDef::new(Alias::new("payload")).blob().not_null())
                .col(
                    ColumnDef::new(Alias::new("pending"))
                        .boolean()
                        .not_null()
                        .default(false),
                )
                .col(
                    ColumnDef::new(Alias::new("created_at"))
                        .timestamp()
                        .not_null(),
                )
                .foreign_key(
                    ForeignKey::create()
                        .from(updates.clone(), Alias::new("document_id"))
                        .to(documents, Alias::new("id")),
                )
                .to_owned(),
        )
        .await?;
        m.create_index(
            Index::create()
                .name("index_y_document_updates_on_document_id_and_pending")
                .table(updates)
                .col(Alias::new("document_id"))
                .col(Alias::new("pending"))
                .to_owned(),
        )
        .await
    }

    async fn down(&self, m: &SchemaManager) -> Result<(), DbErr> {
        m.drop_table(
            Table::drop()
                .table(Alias::new("y_document_updates"))
                .to_owned(),
        )
        .await?;
        m.drop_table(Table::drop().table(Alias::new("y_documents")).to_owned())
            .await
    }
}
