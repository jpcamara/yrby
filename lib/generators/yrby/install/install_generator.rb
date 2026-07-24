# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install` — a DocumentChannel speaking the
    # y-websocket protocol over the gem-owned document storage, plus the
    # storage migration (via yrby:tables). The models (Y::Document,
    # Y::DocumentUpdate) ship in the gem, the way ActionText::RichText does.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_channel
        template "document_channel.rb", "app/channels/document_channel.rb"
      end

      def create_tables
        invoke "yrby:tables"
      end

      def show_next_steps
        say <<~NEXT

          yrby is wired up. Next steps:

            1. Authorize document access: implement `authorized?` in
               app/channels/document_channel.rb (it fails closed until you do).
            2. bin/rails db:migrate
            3. Install the yrby-client npm package and connect an editor:

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
