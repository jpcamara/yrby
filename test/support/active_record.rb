# frozen_string_literal: true

# Shared ActiveRecord bootstrap for the Rails-gem tests. One in-memory
# database, booted once — separate establish_connection calls per file would
# each create a fresh :memory: database and clobber the other's tables.
unless defined?(YRBY_AR_BOOTED)
  YRBY_AR_BOOTED = true

  require "active_record"

  # YRBY_PG_URL runs the suite on Postgres instead, with y_document_updates
  # migrated to the insert-only log (yrby:insert_only_log), e.g.
  #
  #   YRBY_PG_URL=postgres://localhost:5432/yrby_test bundle exec rake test
  YRBY_PG_URL = ENV.fetch("YRBY_PG_URL", nil)
  if YRBY_PG_URL
    require "active_record/connection_adapters/postgresql_adapter"
    require "y/postgres_types"
    Y::PostgresTypes.register(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
    ActiveRecord::Base.establish_connection(url: YRBY_PG_URL, pool: 16)
    ActiveRecord::Base.connection.execute(<<~SQL)
      DROP TABLE IF EXISTS y_document_updates, y_document_updates_slot, y_documents, pages CASCADE;
      DROP FUNCTION IF EXISTS y_document_updates_slot();
    SQL
  else
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  end
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
      t.binary :state_vector
      t.timestamps
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    create_table :y_document_updates do |t|
      t.references :document, null: false, index: false
      t.binary :payload, null: false
      t.datetime :created_at, null: false
      t.index :document_id
    end

    # A host-app model for the record-binding tests (Y::Document.for).
    create_table :pages do |t|
      t.string :title
    end
  end

  if YRBY_PG_URL
    require "erb"
    template = File.expand_path(
      "../../lib/generators/yrby/insert_only_log/templates/insert_only_y_document_updates.rb", __dir__
    )
    version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    eval(ERB.new(File.read(template)).result_with_hash(migration_version: version)) # rubocop:disable Security/Eval
    ActiveRecord::Migration.suppress_messages { InsertOnlyYDocumentUpdates.new.migrate(:up) }
  end
end
