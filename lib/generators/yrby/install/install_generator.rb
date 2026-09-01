# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install` — two channels speaking the
    # y-websocket protocol over the gem's document storage, plus the storage
    # migration (via yrby:tables). The models ship in the gem; only the
    # migration lands in the app. CollaborativeDocumentChannel serves
    # record-bound documents (has_collaborative_document /
    # has_collaborative_rich_text); DocumentChannel serves free-standing
    # documents addressed by key.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_channels
        template "collaborative_document_channel.rb", "app/channels/collaborative_document_channel.rb"
        template "document_channel.rb", "app/channels/document_channel.rb"
      end

      def create_tables
        invoke "yrby:tables"
      end

      def show_next_steps
        say <<~NEXT

          Next steps:

            1. Authorize document access: implement `authorized?` in both
               generated channels (they deny everyone until you do).
            2. bin/rails db:migrate
            3. For a record-bound document, declare it on the model and
               render the editor's element with the form helper:

                 has_collaborative_rich_text :body

                 <%= form.collaborative_document_tag :body, element: "my-editor-collaboration" %>

               CollaborativeDocumentChannel authenticates the signed token,
               stores changes on the record's document, and materializes
               them back into the attribute.
            4. For a free-standing document, install the yrby-client npm
               package and connect an editor by key:

                 import { ActionCableProvider } from "yrby-client"
                 const provider = new ActionCableProvider(doc, consumer,
                   "DocumentChannel", { id: documentId })
                 provider.connect()

          The README's Editors section links working integrations for
          Tiptap, Lexxy, Rhino Editor, and CodeMirror.
        NEXT
      end
    end
  end
end
