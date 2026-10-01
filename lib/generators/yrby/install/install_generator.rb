# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install` runs yrby:tables to create the storage
    # migration. The models and Y::DocumentChannel ship in the gem, so that is
    # the only file it generates by default. Pass --channel to also generate
    # an application channel for custom authorization or room-keyed documents.
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
            2. Render a collaborative document on a page where the user may
               edit the record:

                 <%= collaborative_document_tag @post, :body %>

            3. Install the yrby-client npm package. The tag renders an
               element that connects automatically. Once it syncs, your code
               gets the document and can bind it to any Yjs editor:

                 import "yrby-client/element"

                 document.addEventListener("yrby:synced", ({ target, detail }) => {
                   const editor = bindYourEditor(target, detail.doc, detail.provider)
                   detail.signal.addEventListener("abort", () => editor.destroy(), { once: true })
                 })

          Run with --channel to also generate app/channels/document_channel.rb,
          and implement its authorized? method before you use it.

          The README's Editors section links working integrations for
          Tiptap, Lexxy, Rhino Editor, and CodeMirror.
        NEXT
      end
    end
  end
end
