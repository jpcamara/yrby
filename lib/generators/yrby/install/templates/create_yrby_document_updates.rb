# frozen_string_literal: true

class CreateYrbyDocumentUpdates < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :yrby_document_updates do |t|
      # 16 MB cap on MySQL (mediumblob); a no-op hint on PostgreSQL/SQLite.
      # A single CRDT delta is tiny; snapshots grow with document size.
      t.binary :payload, null: false, limit: 16.megabytes
      t.string :document_key, null: false, index: true
      t.datetime :created_at, null: false
    end
  end
end
