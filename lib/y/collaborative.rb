# frozen_string_literal: true

require "active_support/concern"
require "global_id"

module Y
  # Record-bound collaborative documents for Active Record models.
  #
  # `has_collaborative_document :name` gives a model one Y::Document per
  # record plus the lifecycle around it: find-or-create through the
  # association, a signed-GlobalID token scoped to the attribute, and
  # `refresh_collaborative_document`, which materializes the document into
  # the record's columns through a block the macro registers.
  # `has_collaborative_rich_text :body` builds on it for the common case:
  # render the document to HTML (Y::Lexxy by default) and write it into an
  # Action Text (or plain) attribute.
  #
  # The engine includes this into ActiveRecord::Base and prepends
  # Y::Collaborative::FormBuilder into ActionView's FormBuilder.
  module Collaborative
    extend ActiveSupport::Concern

    class << self
      # The signed-GlobalID purpose for one collaborative attribute. This
      # string is the public contract: a token minted for one attribute
      # verifies only against that attribute's purpose, so it cannot locate
      # a record for any other attribute or channel.
      def sgid_purpose(name) = "yrby/#{name}"

      # Resolves a signed token minted by `collaborative_sgid(name)` back to
      # its record. Returns nil for an invalid, tampered, expired, or
      # wrong-attribute token, and for a record that no longer exists.
      def locate(sgid, name)
        GlobalID::Locator.locate_signed(sgid, for: sgid_purpose(name))
      rescue ActiveRecord::RecordNotFound
        nil
      end

      attr_writer :rich_text_renderer, :identity, :channel_name

      # How has_collaborative_rich_text renders a document to HTML when the
      # macro got no renderer of its own. Set once for the app; the lambda
      # receives the rebuilt Y::Doc plus record:/name: keywords.
      def rich_text_renderer
        @rich_text_renderer ||= ->(doc, **) { Y::Lexxy.new(doc).to_html }
      end

      # The channel collaborative_document_tag points elements at by
      # default; yrby:install generates it.
      def channel_name
        @channel_name ||= "CollaborativeDocumentChannel"
      end

      # Presence identity, called with the view context; returns
      # { name:, color: } (a nil color gets a stable one derived from the
      # name).
      def identity
        @identity ||= lambda do |view|
          user = view.respond_to?(:current_user) ? view.current_user : nil
          # Use Anonymous when no display name is available.
          name = user && %i[name username handle].lazy.filter_map { |a| user.try(a).presence }.first
          { name: name || "Anonymous", color: nil }
        end
      end

      # A stable, readable presence color per collaborator name.
      def collaborator_color(name)
        "hsl(#{name.to_s.each_byte.reduce(0) { |acc, b| ((acc * 31) + b) % 360 }}, 70%, 45%)"
      end
    end

    class_methods do
      # The primitive: one named collaborative document per record. The
      # block is the materialize step — called by
      # refresh_collaborative_document with the rebuilt Y::Doc and the
      # record, it assigns whatever columns derive from the document.
      # Returning false from it skips the save (nothing to materialize).
      # Without a block the document still syncs and authorizes; refresh
      # just has nothing to do.
      def has_collaborative_document(name, encrypted: false, &materialize) # rubocop:disable Naming/PredicatePrefix
        include Model unless include?(Model)
        name = name.to_sym
        self.collaborative_document_names = (collaborative_document_names | [name]).freeze
        if materialize
          self.collaborative_document_materializers =
            collaborative_document_materializers.merge(name => materialize).freeze
        end

        # encrypted: true stores CRDT state through Y::EncryptedDocument.
        # Encrypting the materialized columns is the model's own concern
        # (`encrypts`, or Action Text's encrypted rich text).
        document_class = encrypted ? "Y::EncryptedDocument" : "Y::Document"
        has_one :"collaborative_document_#{name}", -> { where(name: name) },
                class_name: document_class, as: :record, inverse_of: :record, dependent: :destroy
      end

      # The rich-text convenience: materialize the document as HTML into
      # the attribute. With Action Text present the attribute is declared
      # `has_rich_text` (options pass through, `encrypted:` included);
      # without it, the HTML goes to a plain column of the same name.
      # The renderer defaults to Y::Collaborative.rich_text_renderer
      # (Y::Lexxy); pass renderer: or a block to render differently, e.g.
      # `has_collaborative_rich_text(:body) { |doc| Y::Tiptap.new(doc).to_html }`.
      def has_collaborative_rich_text(name, renderer: nil, **options, &block) # rubocop:disable Naming/PredicatePrefix
        raise ArgumentError, "pass renderer: or a block, not both" if renderer && block

        render = renderer || block
        has_rich_text(name, **options) if respond_to?(:has_rich_text)
        has_collaborative_document(name, encrypted: options[:encrypted] || false) do |doc, record|
          html = (render || Y::Collaborative.rich_text_renderer).call(doc, record: record, name: name.to_sym)
          next false if html.nil?

          record.public_send("#{name}=", html)
        end
      end
    end

    # The instance API, present only on models that declared a document.
    module Model
      extend ActiveSupport::Concern

      included do
        class_attribute :collaborative_document_names, instance_writer: false, default: [].freeze
        class_attribute :collaborative_document_materializers, instance_writer: false, default: {}.freeze
      end

      def collaborative_document?(name) = collaborative_document_names.include?(name.to_sym)

      # The document, if collaboration has started (nil until the first join).
      def collaborative_document(name) = public_send("collaborative_document_#{name}")

      # Creates the document on first use. The association supplies the
      # class, so an encrypted attribute gets a Y::EncryptedDocument.
      def find_or_create_collaborative_document(name)
        ensure_collaborative!(name)
        collaborative_document(name) || begin
          association(:"collaborative_document_#{name}").klass.for(self, name)
          public_send("reload_collaborative_document_#{name}")
        end
      end

      # A signed token a channel can trade back for this record with
      # Y::Collaborative.locate — but only for this attribute.
      def collaborative_sgid(name)
        ensure_collaborative!(name)
        to_sgid(for: Y::Collaborative.sgid_purpose(name)).to_s
      end

      # Reloads the document and runs the registered materialize block
      # while holding the record lock, then saves the assigned columns.
      # Returns false when the document has no state, when the block
      # declines (returns false), or when nothing registered a block.
      def refresh_collaborative_document(name)
        ensure_collaborative!(name)
        materialize = collaborative_document_materializers[name.to_sym]
        document = collaborative_document(name)
        return false unless materialize && document

        with_lock do
          strict_loading!(false) if strict_loading? # materializers may lazily load (Action Text's writer does)
          state = document.reload.load_state
          break false if state.nil?

          doc = Y::Doc.new
          doc.apply_update(state)
          break false if materialize.call(doc, self) == false

          save!(validate: false) # collaboration updates should not run unrelated model validations
          true
        end
      end

      private

      def ensure_collaborative!(name)
        return if collaborative_document?(name)

        raise ArgumentError, "#{name.inspect} is not collaborative on #{self.class.name}"
      end
    end
  end
end

require "y/collaborative/form_builder"
