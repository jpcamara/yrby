# frozen_string_literal: true

class CreateYTables < ActiveRecord::Migration<%= migration_version %>
  def change
    # One row per collaborative document, addressed by key. The optional
    # polymorphic record + name bind it to a model; key-only documents leave
    # them nil. materialized_at: when a projection (rendered HTML, search
    # text) was last built from the log.
    create_table :y_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      t.datetime :materialized_at
      t.timestamps
      # Unique indexes treat NULLs as distinct on every database, so key-only
      # documents (all three columns nil) coexist with or without the WHERE.
      # The predicate keeps them out of the index; MySQL drops it, harmlessly.
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    # The CRDT update log: one delta (or compacted snapshot) per row.
    create_table :y_document_updates do |t|
      t.references :document, null: false, foreign_key: { to_table: :y_documents }
      # Longblob on MySQL, a no-op on PostgreSQL/SQLite. Deltas are tiny,
      # but a compacted snapshot holds the entire document; a 16 MB cap
      # would make compaction fail and block appends.
      t.binary :payload, null: false, limit: 4.gigabytes - 1
      t.datetime :created_at, null: false
    end
  end
end
