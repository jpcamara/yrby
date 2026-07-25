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
    # For the Y::UpdateLog module tests: the default key column...
    create_table :module_keyed_updates do |t|
      t.binary :payload, null: false
      t.string :document_key, null: false, index: true
      t.datetime :created_at, null: false
    end

    # ...and an overridden one.
    create_table :parent_keyed_updates do |t|
      t.binary :payload, null: false
      t.integer :parent_id, null: false, index: true
      t.datetime :created_at, null: false
    end

    # The gem-owned models, as yrby:tables migrates them.
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

    create_table :yrby_document_updates do |t|
      t.references :document, null: false
      t.binary :payload, null: false
      t.datetime :created_at, null: false
    end

    # A host-app model for the record-binding tests (Y::Document.for).
    create_table :pages do |t|
      t.timestamps
    end
  end
end
