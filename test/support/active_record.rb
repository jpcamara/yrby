# frozen_string_literal: true

# Shared ActiveRecord bootstrap for the Rails-gem tests. One in-memory
# database, booted once — separate establish_connection calls per file would
# each create a fresh :memory: database and clobber the other's tables.
unless defined?(YRBY_AR_BOOTED)
  YRBY_AR_BOOTED = true

  require "active_record"

  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    # The gem-owned models, as yrby:tables migrates them.
    create_table :y_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      t.binary :state
      t.bigint :changes_count, null: false, default: 0
      t.bigint :materialized_changes_count
      t.datetime :changed_at
      t.datetime :materialized_at
      t.timestamps
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    create_table :y_document_updates do |t|
      t.references :document, null: false
      t.binary :payload, null: false
      t.boolean :pending, null: false, default: false
      t.datetime :created_at, null: false
    end

    # A host-app model for the record-binding tests (Y::Document.for).
    create_table :pages do |t|
      t.string :title
    end
  end
end
