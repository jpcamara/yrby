# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Yrby
  module Generators
    # `bin/rails generate yrby:state_vector`: adds y_documents.state_vector
    # to tables created before it existed. Compaction stores the snapshot's
    # state vector there, so the sync handshake doesn't read the snapshot.
    # Without the column everything still works; the handshake reads the
    # state vector from the snapshot's bytes, and rows compacted before the
    # migration do the same until their next compaction.
    class StateVectorGenerator < ::Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "add_state_vector_to_y_documents.rb",
                           File.join(db_migrate_path, "add_state_vector_to_y_documents.rb")
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
