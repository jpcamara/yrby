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

      # Records one change and returns once it's saved. The channel waits for
      # this to return before it acknowledges or broadcasts the change.
      def append(update) = document_row.append(update)

      # A signed grant for this document, what a page or a Ruby client
      # subscribes with. It's a signed GlobalID scoped to this attribute, and
      # Y::Collaborative.locate turns it back into the record. Pass
      # expires_in: to limit how long it lasts. Without it GlobalID's own
      # default applies, which is one month under Rails. The option goes
      # through only when it's given, because an explicit nil would mean
      # "never expire".
      def grant(expires_in: nil)
        options = { for: Y::Collaborative.sgid_purpose(name) }
        options[:expires_in] = expires_in if expires_in
        record.to_sgid(**options).to_s
      end

      # The channel that accepts this document's grant. A gem with its own
      # grants and channel, such as lexxy-realtime, returns its own document
      # with both.
      def channel = "Y::DocumentChannel"

      # Edits the document from Ruby the way a browser does: yields the
      # current document, records what the block changed, and broadcasts it so
      # open editors apply it. Returns the update, or nil when the block
      # changed nothing.
      #
      #   post.collaborative_document(:body).edit do |doc|
      #     Y::Lexxy.append_paragraph(doc, "Reviewed by ops.")
      #   end
      def edit
        doc = y_doc
        update = doc.edit { yield doc }
        return unless update

        append(update)
        Y::ActionCable.broadcast(key, update)
        update
      end

      # Builds a new Y::Doc from storage on every call.
      def y_doc
        Y::Doc.new.tap do |doc|
          state = load_state
          doc.apply_update(state) if state
        end
      end

      # The key clients sync the document under, such as "post/1/body". If a
      # key-only channel created the document before it was linked to a
      # record, this returns that original key.
      def key = existing_row&.key || Y::Document.key_for(record, name)

      # Finds or creates the Y::Document or Y::EncryptedDocument row. Writes
      # and maintenance work such as compaction go through it.
      def document_row = document_class.for(record, name)

      private

      # Returns the row if it exists without creating one, so reading a
      # document never adds a row. It selects only id and key because the
      # row's load_state reads the snapshot itself, and loading the snapshot
      # here too would fetch it twice.
      def existing_row = document_class.select(:id, :key).find_by(record:, name:)

      def document_class = record.class.collaborative_document_class(name)
    end
  end
end
