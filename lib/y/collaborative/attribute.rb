# frozen_string_literal: true

module Y
  module Collaborative
    # A record-bound document capability. Storage selection is shared by Ruby
    # callers and the channel, including adapters that use no Y::Document row.
    class Attribute
      attr_reader :record, :name

      def initialize(record, name)
        raise ArgumentError, "collaboration requires a persisted record" unless record.persisted?

        @record = record
        @name = name.to_s.dup.freeze
      end

      def key
        storage ? Y::Document.key_for(record, name) : document.key
      end

      def load_state
        storage ? storage.load(record, name) : document.load_state
      end

      # Custom writes must return only after durable persistence, and raise on
      # failure. The channel acknowledges and broadcasts only after this returns.
      def append(update)
        storage ? storage.write(record, name, update) : document.append(update)
      end

      # A fresh native document for reading/rendering; never a cached replica.
      def doc
        Y::Doc.new.tap do |doc|
          state = load_state
          doc.apply_update(state) if state
        end
      end

      # Explicit access to built-in storage operations such as compaction.
      def document
        record.class.collaborative_document_class(name).for(record, name)
      end

      private

      def storage
        record.class.collaborative_document_options.dig(name, :storage)
      end
    end
  end
end
