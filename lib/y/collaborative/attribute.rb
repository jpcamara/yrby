# frozen_string_literal: true

module Y
  module Collaborative
    # One attribute's document on one record. Ruby callers and the channel
    # both go through it, so they share one storage choice, including custom
    # adapters that have no Y::Document row.
    class Attribute
      attr_reader :record, :name

      def initialize(record, name)
        raise ArgumentError, "collaboration requires a persisted record" unless record.persisted?

        @record = record
        @name = name.to_s.dup.freeze
      end

      # Never creates a row. A stored binding keeps whatever key it was given;
      # otherwise this is the conventional record/attribute key.
      def key
        return Y::Document.key_for(record, name) if storage

        stored = record.class.collaborative_document_class(name).find_by(record: record, name: name)
        stored&.key || Y::Document.key_for(record, name)
      end

      def load_state
        storage ? storage.load(record, name) : document.load_state
      end

      # Custom writes must return only after durable persistence, and raise on
      # failure. The channel acknowledges and broadcasts only after this returns.
      def append(update)
        storage ? storage.write(record, name, update) : document.append(update)
      end

      # A fresh Y::Doc rebuilt from storage on every call. Nothing is cached.
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
