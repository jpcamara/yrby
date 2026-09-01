# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Yrby
  module Generators
    # `bin/rails generate yrby:tables`: the migration for the gem-owned
    # document models (Y::Document + Y::DocumentUpdate). Invoked by
    # yrby:install, and by other gems building on the same storage.
    #
    # Template notes (kept here, not in the emitted migration): state is
    # 1.gigabyte - 1 — the largest limit every adapter accepts. MySQL maps
    # anything over 16 MB to longblob (a compacted snapshot is the whole
    # document; a 16 MB cap would break compaction); Postgres raises above
    # 1 GB - 1 and ignores the limit on bytea otherwise; SQLite ignores
    # limits. Payload is 16.megabytes - 1 (one update can carry a big paste
    # or a client's accumulated offline edits; the 64 KB default blob is
    # too small).
    # The partial unique index's WHERE only keeps
    # key-only rows out of the index: uniqueness holds without it, since
    # unique indexes treat NULLs as distinct on every supported database,
    # and MySQL drops the predicate harmlessly. y_document_updates indexes
    # (document_id, pending) instead of bare document_id: the prefix
    # serves the tail and foreign-key lookups, and the pair serves the
    # clean-row count every append runs.
    class TablesGenerator < ::Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "create_y_tables.rb",
                           File.join(db_migrate_path, "create_y_tables.rb")
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
