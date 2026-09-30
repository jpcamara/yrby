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

      # The document as update bytes, or nil before the first write.
      def load_state = existing_row&.load_state

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
      # its original key.
      def key = existing_row&.key || Y::Document.key_for(record, name)

      # The Y::Document (or Y::EncryptedDocument) row, created if missing. Writes
      # and maintenance such as compaction use it.
      def document_row = document_class.for(record, name)

      private

      # The row if it already exists. Reads use it, so looking at a document
      # never creates one. Only the id and key are loaded. The row's load_state
      # re-reads the snapshot itself, so loading it here would fetch it twice.
      def existing_row = document_class.select(:id, :key).find_by(record:, name:)

      def document_class = record.class.collaborative_document_class(name)
    end
  end
end
