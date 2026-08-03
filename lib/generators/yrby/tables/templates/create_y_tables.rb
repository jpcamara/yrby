# frozen_string_literal: true

class CreateYTables < ActiveRecord::Migration<%= migration_version %>
  def change
    # One row per collaborative document, addressed by key. The optional
    # polymorphic record + name bind it to a model; key-only documents leave
    # them nil. state holds the merged snapshot (the update rows are only
    # the uncompacted tail). changed_at: when content last changed.
    # materialized_at: when a projection (rendered HTML, search text) was
    # last built; consumers compare it against changed_at.
    create_table :y_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      # The snapshot is the whole document. Longblob on MySQL, a no-op on
      # PostgreSQL/SQLite; a 16 MB cap would make folding fail on a large
      # document and block appends.
      t.binary :state, limit: 4.gigabytes - 1
      t.datetime :changed_at
      t.datetime :materialized_at
      t.timestamps
      # Unique indexes treat NULLs as distinct on every database, so key-only
      # documents (all three columns nil) coexist with or without the WHERE.
      # The predicate keeps them out of the index; MySQL drops it, harmlessly.
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    # The uncompacted tail: one CRDT delta per row, folded into the
    # document's state and deleted once the tail reaches the threshold.
    # pending marks causally-gapped rows, quarantined until they heal.
    create_table :y_document_updates do |t|
      t.references :document, null: false, foreign_key: { to_table: :y_documents }
      # Mediumblob on MySQL: a delta is one edit batch — a large paste can
      # exceed the 64 KB default blob, but never approaches 16 MB.
      t.binary :payload, null: false, limit: 16.megabytes - 1
      t.boolean :pending, null: false, default: false
      t.datetime :created_at, null: false
    end
  end
end
