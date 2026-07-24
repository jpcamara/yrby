# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Yrby
  module Generators
    # `bin/rails generate yrby:tables` — the migration for the gem-owned
    # document models (Y::Document + Y::DocumentUpdate). Invoked by
    # yrby:install, and by other gems building on the same storage.
    class TablesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "create_yrby_tables.rb",
                           File.join(db_migrate_path, "create_yrby_tables.rb")
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
