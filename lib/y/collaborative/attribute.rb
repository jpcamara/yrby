# frozen_string_literal: true

module Y
  module Collaborative
    # The collaborative document for one attribute of one record, such as a
    # post's body. Ruby code and the shipped channel both use it, so they read
    # and write the same rows.
    class Attribute
      attr_reader :record, :name

      def initialize(record, name)
        raise ArgumentError, "collaboration requires a persisted record" unless record.persisted?

        @record = record
        @name = name.to_s.dup.freeze
      end

      # The document as update bytes, or nil before the first write. Never
      # creates a row. Only the id is loaded: the row's load_state re-reads the
      # snapshot fresh, so selecting it here would fetch the largest column twice.
      def load_state = document_class.select(:id).find_by(record:, name:)&.load_state

      # Saves one change and returns once it is recorded. The channel
      # acknowledges and broadcasts only after this returns.
      def append(update) = document_row.append(update)

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
        document_class.select(:key).find_by(record:, name:)&.key || Y::Document.key_for(record, name)
      end

      # The Y::Document (or Y::EncryptedDocument) row, created if missing, for
      # maintenance such as compaction.
      def document_row = document_class.for(record, name)

      private

      def document_class = record.class.collaborative_document_class(name)
    end
  end
end
