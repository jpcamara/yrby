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

      def create_channel
        template "document_channel.rb", "app/channels/document_channel.rb"
      end

      def create_model
        template "yrby_document_update.rb", "app/models/yrby_document_update.rb"
      end

      def create_store
        template "yrby_document_store.rb", "app/models/yrby_document_store.rb"
      end

      def create_migration_file
        migration_template "create_yrby_document_updates.rb",
                           "db/migrate/create_yrby_document_updates.rb"
      end

      def show_next_steps
        say <<~NEXT

          yrby is wired up. Next steps:

            1. bin/rails db:migrate
            2. npm install yrby-client   (or yarn/bun/pnpm)
            3. Connect an editor — the client side is a provider plus your
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

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
