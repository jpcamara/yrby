# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Yrby
  module Generators
    # `bin/rails generate yrby:insert_only_log`: on Postgres 13 or later,
    # turns y_document_updates into the insert-only log (see
    # Y::Document.rotate_log_every). The migration rebuilds the table with
    # two partitions and a txid column and copies the rows over, so it holds
    # an exclusive lock on the table while it runs.
    class InsertOnlyLogGenerator < ::Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "insert_only_y_document_updates.rb",
                           File.join(db_migrate_path, "insert_only_y_document_updates.rb")
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
