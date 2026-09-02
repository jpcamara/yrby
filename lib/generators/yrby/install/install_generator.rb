# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install`: the storage migration (via
    # yrby:tables). That is the whole install: the models and the
    # Y::DocumentChannel that syncs through them ship in the gem, the way
    # Turbo ships Turbo::StreamsChannel. Apps that want their own channel
    # (custom storage, room-keyed documents) write one with Y::ActionCable;
    # see the README.
    class InstallGenerator < ::Rails::Generators::Base
      def create_tables
        invoke "yrby:tables"
      end

      def show_next_steps
        say <<~NEXT

          Next steps:

            1. bin/rails db:migrate
            2. Render a collaborative document where the page is authorized
               to edit the record:

                 <%= collaborative_document_tag @post, :body %>

            3. Install the yrby-client npm package and connect the document
               to any editor that speaks Yjs:

                 import * as Y from "yjs"
                 import { createConsumer } from "@rails/actioncable"
                 import { ActionCableProvider } from "yrby-client"

                 const el = document.querySelector("[data-collaborative-document]")
                 const ydoc = new Y.Doc()
                 const provider = new ActionCableProvider(ydoc, createConsumer(),
                   el.dataset.channel, { grant: el.dataset.grant, name: el.dataset.name })
                 provider.connect()

          The README's Editors section links working integrations for
          Tiptap, Lexxy, Rhino Editor, and CodeMirror.
        NEXT
      end
    end
  end
end
