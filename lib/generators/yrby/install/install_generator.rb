# frozen_string_literal: true

require "rails/generators"
require "generators/yrby/tables/tables_generator"

module Yrby
  module Generators
    # `bin/rails generate yrby:install` runs yrby:tables to create the storage
    # migration. The models and Y::DocumentChannel ship in the gem, so that is
    # the only file it generates by default. Pass --channel to also generate
    # an application channel for custom authorization or room-keyed documents.
    # In an import-map app it also pins the JavaScript the gem ships.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      class_option :channel, type: :boolean, default: false, desc: "Generate a custom DocumentChannel"

      def create_channel
        template "document_channel.rb", "app/channels/document_channel.rb" if options[:channel]
      end

      def create_tables
        invoke "yrby:tables"
      end

      # Each shared module has one pin, so the page loads one copy of it:
      #
      # - yrby-client and yrby-client/element point at one file, so the page
      #   has one session store and one <yrby-document> class.
      # - yjs is one copy, because Yjs checks constructors with instanceof.
      #   The app's editor binding imports it through this pin too.
      # - @rails/actioncable is Rails' own file. <yrby-document> loads it for
      #   its default consumer.
      #
      # A pin the app already has is left alone, so re-running the generator
      # adds only what is missing.
      IMPORTMAP_PINS = {
        "yrby-client" => "yrby/yrby-client.js",
        "yrby-client/element" => "yrby/yrby-client.js",
        "yjs" => "yrby/yjs.js",
        "@rails/actioncable" => "actioncable.esm.js"
      }.freeze

      def add_importmap_pins
        importmap = File.join(destination_root, "config/importmap.rb")
        return unless File.exist?(importmap)

        existing = File.read(importmap)
        missing = IMPORTMAP_PINS.reject { |name, _| existing.match?(/^\s*pin\s+["']#{Regexp.escape(name)}["']/) }
        return if missing.empty?

        append_to_file "config/importmap.rb", <<~RUBY

          # yrby. One pin per shared module, so the page loads one copy of each.
          #{missing.map { |name, path| %(pin "#{name}", to: "#{path}") }.join("\n")}
        RUBY
      end

      def show_next_steps
        say <<~NEXT

          Next steps:

            1. bin/rails db:migrate
            2. Render a collaborative document on a page where the user may
               edit the record:

                 <%= collaborative_document_tag @post, :body %>

            3. Load yrby-client. With import maps, the generator added pins.
               With a bundler, install the yrby-client and yjs npm packages.
               The tag renders an element that connects automatically. Once
               it syncs, your code gets the document and can bind it to any
               Yjs editor:

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
