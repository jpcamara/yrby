# frozen_string_literal: true

# Shared ActiveRecord bootstrap for the Rails-gem tests. One in-memory
# database, booted once — separate establish_connection calls per file would
# each create a fresh :memory: database and clobber the other's tables.
unless defined?(YRBY_AR_BOOTED)
  YRBY_AR_BOOTED = true

  require "active_record"

  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  # Test-only keys so the encrypted model variants can round-trip.
  ActiveRecord::Encryption.configure(
    primary_key: "test-primary-key" * 2,
    deterministic_key: "test-deterministic-key" * 2,
    key_derivation_salt: "test-key-derivation-salt" * 2
  )
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    # The gem-owned models, as yrby:tables migrates them.
    create_table :y_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      t.binary :state
      t.timestamps
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    create_table :y_document_updates do |t|
      t.references :document, null: false, index: false
      t.binary :payload, null: false
      t.boolean :pending, null: false, default: false
      t.datetime :created_at, null: false
      t.index %i[document_id pending]
    end

    # A host-app model for the record-binding tests (Y::Document.for).
    create_table :pages do |t|
      t.string :title
    end

    # A host-app model for the yrby-forms tests (has_collaborative_fields),
    # with one column per tier-detection case.
    create_table :tickets do |t|
      t.string :title
      t.string :status
      t.integer :priority
      t.boolean :urgent
      t.date :due_on
      t.string :summary
      t.text :description
    end
  end
end
