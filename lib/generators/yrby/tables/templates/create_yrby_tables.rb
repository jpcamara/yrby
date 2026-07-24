# frozen_string_literal: true

class CreateYrbyTables < ActiveRecord::Migration<%= migration_version %>
  def change
    # One row per collaborative document: the identity a transport key points
    # at. The optional polymorphic record + name bind a document to a Rails
    # model; key-only documents leave them nil. materialized_at is for
    # projections — the log version they were last built from.
    create_table :yrby_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      t.datetime :materialized_at
      t.timestamps
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_yrby_documents_on_record_and_name"
    end

    # The CRDT update log: one delta (or compacted snapshot) per row.
    create_table :yrby_document_updates do |t|
      t.references :document, null: false, foreign_key: { to_table: :yrby_documents }
      # Mediumblob (~16 MB cap) on MySQL — one byte over selects longblob.
      # A no-op hint on PostgreSQL/SQLite. A delta is tiny; snapshots grow
      # with document size.
      t.binary :payload, null: false, limit: 16.megabytes - 1
      t.datetime :created_at, null: false
    end
  end
end
