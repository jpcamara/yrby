# frozen_string_literal: true

require "base64"

module YrbLite
  # Simple Y.js sync protocol for ActionCable
  #
  # Include this module in your ActionCable channel to enable Y.js document sync.
  # Works with both ActionCable and AnyCable.
  #
  # Example:
  #   class DocumentChannel < ApplicationCable::Channel
  #     include YrbLite::Sync
  #
  #     def subscribed
  #       stream_for document
  #       sync_to document
  #     end
  #
  #     def receive(data)
  #       sync_update document, data
  #     end
  #
  #     private
  #
  #     def document
  #       @document ||= Document.find(params[:id])
  #     end
  #   end
  #
  module Sync
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Configure persistence callbacks
      #
      #   class DocumentChannel < ApplicationCable::Channel
      #     include YrbLite::Sync
      #
      #     on_load ->(channel, key) { Document.find_by(key: key)&.content }
      #     on_save ->(channel, key, update) { Document.find_by(key: key)&.update!(content: update) }
      #   end
      #
      def on_load(callable = nil, &block)
        @on_load = callable || block if callable || block
        @on_load
      end

      def on_save(callable = nil, &block)
        @on_save = callable || block if callable || block
        @on_save
      end
    end

    # Get or create a Y.Doc for the given key
    def doc_for(key)
      YrbLite::Sync.docs[key] ||= begin
        doc = YrbLite::Doc.new
        if (loader = self.class.on_load)
          if (state = loader.call(self, key))
            doc.apply_update(state)
          end
        end
        doc
      end
    end

    # Start syncing with a client - sends our state vector
    # Call this in `subscribed` after `stream_for`
    def sync_to(model_or_key)
      key = sync_key(model_or_key)
      doc = doc_for(key)

      # Send SyncStep1 so client can send us what we're missing
      transmit({ "update" => Base64.strict_encode64(doc.sync_step1) })
    end

    # Handle incoming sync message from client
    # Call this in `receive`
    def sync_update(model_or_key, data)
      key = sync_key(model_or_key)
      doc = doc_for(key)
      origin = data["origin"] || connection_identifier

      raw = Base64.strict_decode64(data["update"])
      result = doc.handle_sync_message(raw)

      # Persist if document was modified (SyncStep2 or Update received)
      if result && result[1] >= 1 # MSG_SYNC_STEP2 or MSG_SYNC_UPDATE
        persist_doc(key, doc)
      end

      # Broadcast to all subscribers (they'll filter by origin)
      broadcast_data = { "update" => data["update"], "origin" => origin }

      if model_or_key.respond_to?(:to_global_id)
        self.class.broadcast_to(model_or_key, broadcast_data)
      else
        ActionCable.server.broadcast(key, broadcast_data)
      end

      # Send response directly to this client if needed (e.g., SyncStep2 reply)
      if result && result[2] && !result[2].empty?
        transmit({ "update" => Base64.strict_encode64(result[2]) })
      end
    end

    # Override in channel to filter out own messages
    def receive(data)
      return if data["origin"] == connection_identifier

      transmit(data)
    end

    private

    def sync_key(model_or_key)
      if model_or_key.respond_to?(:to_global_id)
        model_or_key.to_global_id.to_s
      else
        model_or_key.to_s
      end
    end

    def connection_identifier
      connection.connection_identifier rescue object_id.to_s
    end

    def persist_doc(key, doc)
      return unless (saver = self.class.on_save)

      saver.call(self, key, doc.encode_state_as_update)
    end

    # In-memory document storage (shared across channels)
    def self.docs
      @docs ||= {}
    end

    # Clear all docs (useful for testing)
    def self.reset!
      @docs = {}
    end
  end
end
