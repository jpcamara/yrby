# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Yrby
  module Generators
    # `bin/rails generate yrby:install`
    #
    # Wires a Rails app for collaborative documents: a channel speaking the
    # y-websocket protocol, an ActiveRecord-backed durable store with
    # compaction, and its migration. The generated files are plain app code —
    # rename, reshape, or replace the store freely; the channel only needs
    # `on_load` and `on_change` to answer with your storage.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      # The update-log model's class name; the table, the store class, and the
      # migration all derive from it, so the storage carries your naming:
      #
      #   bin/rails g yrby:install                    # YrbyDocumentUpdate + YrbyDocumentStore
      #   bin/rails g yrby:install DocumentRevision   # DocumentRevision + DocumentRevisionStore
      argument :model_name, type: :string, default: "YrbyDocumentUpdate",
                            banner: "UpdateModelName"

      def create_channel
        template "document_channel.rb", "app/channels/document_channel.rb"
      end

      def create_model
        template "yrby_document_update.rb", "app/models/#{model_file_name}.rb"
      end

      def create_store
        template "yrby_document_store.rb", "app/models/#{store_file_name}.rb"
      end

      def create_migration_file
        migration_template "create_yrby_document_updates.rb",
                           File.join(db_migrate_path, "create_#{table_name}.rb")
      end

      def show_next_steps
        say <<~NEXT

          yrby is wired up. Next steps:

            1. Authorize document access: implement `authorized?` in
               app/channels/document_channel.rb (it fails closed until you do).
            2. bin/rails db:migrate
            3. npm install yrby-client   (or yarn/bun/pnpm)
            4. Connect an editor — the client side is a provider plus your
               editor's Yjs binding:

                 import { ActionCableProvider } from "yrby-client"
                 const provider = new ActionCableProvider(doc, consumer,
                   "DocumentChannel", { id: documentId })
                 provider.connect()

          The README's Editors section links working integrations for
          Tiptap, Lexxy, Rhino Editor, and CodeMirror.
        NEXT
      end

      private

      def model_class_name
        model_name.camelize
      end

      # A trailing "Update" folds into the store name so the default pair
      # reads naturally: YrbyDocumentUpdate -> YrbyDocumentStore,
      # DocumentRevision -> DocumentRevisionStore.
      def store_class_name
        "#{model_class_name.sub(/Update\z/, "")}Store"
      end

      def table_name
        model_class_name.tableize.tr("/", "_")
      end

      def model_file_name
        model_class_name.underscore
      end

      def store_file_name
        store_class_name.underscore
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
