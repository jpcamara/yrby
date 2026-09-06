# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install`: the storage migration (via
    # yrby:tables). That is the whole install: the models and the
    # Y::DocumentChannel that syncs through them ship in the gem, the way
    # Turbo ships Turbo::StreamsChannel. Apps that want their own channel
    # (custom authorization, room-keyed documents) can request --channel.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      class_option :channel, type: :boolean, default: false, desc: "Generate a custom DocumentChannel"

      def create_channel
        template "document_channel.rb", "app/channels/document_channel.rb" if options[:channel]
      end

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

            3. Install the yrby-client npm package. The tag is an
               auto-connecting element; your code receives the synced
               document and hands it to any editor that speaks Yjs:

                 import "yrby-client/element"

                 document.addEventListener("yrby:synced", ({ target, detail }) => {
                   const editor = bindYourEditor(target, detail.doc, detail.provider)
                   detail.signal.addEventListener("abort", () => editor.destroy(), { once: true })
                 })

          --channel also generates app/channels/document_channel.rb. Implement
          its authorized? method before using that explicit custom channel.

          The README's Editors section links working integrations for
          Tiptap, Lexxy, Rhino Editor, and CodeMirror.
        NEXT
      end
    end
  end
end
