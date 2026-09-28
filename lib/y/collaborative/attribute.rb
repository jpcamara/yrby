# frozen_string_literal: true

module Y
  module Collaborative
    # The collaborative document for one attribute of one record, such as a
    # post's body. Ruby code and the shipped channel both use it, so they read
    # and write the same place.
    class Attribute
      # The built-in tables, with the same load/write interface as a custom store.
      BuiltInStore = Data.define(:model) do
        # Only the id is loaded: the row's load_state re-reads the snapshot
        # fresh, so selecting it here would fetch the largest column twice.
        def load(record, name) = model.select(:id).find_by(record:, name:)&.load_state
        def write(record, name, update) = model.for(record, name).append(update)
      end

      attr_reader :record, :name

      def initialize(record, name)
        raise ArgumentError, "collaboration requires a persisted record" unless record.persisted?

        @record = record
        @name = name.to_s.dup.freeze
      end

      # The document as update bytes, or nil before the first write.
      def load_state = store.load(record, name)

      # Saves one change. Returns only once it is durable and raises on failure;
      # the channel acknowledges and broadcasts only after this returns.
      def append(update) = store.write(record, name, update)

      # A Y::Doc built fresh from storage on every call.
      def y_doc
        Y::Doc.new.tap do |doc|
          state = load_state
          doc.apply_update(state) if state
        end
      end

      # The document's name on the wire, such as "post/1/body". A document first
      # created by a key-only channel, before it was linked to a record, keeps
      # its original key. Never creates a row.
      def key
        existing = custom_store ? nil : document_class.select(:key).find_by(record:, name:)
        existing&.key || Y::Document.key_for(record, name)
      end

      # The Y::Document (or Y::EncryptedDocument) row, created if missing, for
      # maintenance such as compaction. Raises for a custom store, which has none.
      def document_row = document_class.for(record, name)

      private

      def store = custom_store || BuiltInStore.new(document_class)
      def custom_store = record.class.collaborative_document_options.dig(name, :storage)
      def document_class = record.class.collaborative_document_class(name)
    end
  end
end
