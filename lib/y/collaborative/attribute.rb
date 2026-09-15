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

        stored_record&.key || Y::Document.key_for(record, name)
      end

      # The document's state as update bytes, or nil when nothing has been
      # written yet. A custom store's load(record, name) returns the same.
      # Reads never create a row; the first append does.
      def load_state
        storage ? storage.load(record, name) : stored_record&.load_state
      end

      # Custom writes must return only after durable persistence, and raise on
      # failure. The channel acknowledges and broadcasts only after this returns.
      def append(update)
        storage ? storage.write(record, name, update) : collaborative_record.append(update)
      end

      # A fresh Y::Doc rebuilt from storage on every call. Nothing is cached.
      def y_doc
        Y::Doc.new.tap do |doc|
          state = load_state
          doc.apply_update(state) if state
        end
      end

      # The built-in storage row (Y::Document or Y::EncryptedDocument), created
      # on first use, for operations such as compaction. Raises for a custom
      # store, which has no row.
      def collaborative_record
        model_class.for(record, name)
      end

      private

      # The built-in model that stores this attribute's document.
      def model_class = record.class.collaborative_document_class(name)

      # The row, when one exists. Never creates one.
      def stored_record = model_class.find_by(record: record, name: name)

      def storage
        record.class.collaborative_document_options.dig(name, :storage)
      end
    end
  end
end
