# frozen_string_literal: true

require "y/action_cable"

module Y
  # The sync channel for Rage (rage-rb). `include Y::Rage` in a
  # Rage::Cable::Channel gives it the same API as Y::ActionCable: on_load,
  # on_change, authorized?, sync_subscribed, and sync_receive. Broadcasts go
  # through Rage.cable and logs through Rage.logger.
  #
  #   class DocumentChannel < Rage::Cable::Channel
  #     include Y::Rage
  #
  #     def subscribed
  #       sync_subscribed params[:id]
  #     end
  #
  #     def receive(data)
  #       sync_receive(data)
  #     end
  #
  #     private
  #
  #     def authorized?(key) = true
  #   end
  #
  # Requiring this file also loads Y::Document and Y::DocumentUpdate, the
  # storage the hooks default to, since Rage has no Rails engine to load them.
  module Rage
    def self.included(base)
      # Channel comes first so its methods win over Sync's.
      base.include(Channel, Y::ActionCable::Sync)
    end

    # Sends an update to everyone subscribed to a document, from outside a
    # channel: a controller, a job, a console. Record the update first. This
    # only distributes it.
    def self.broadcast(key, update)
      encoded = Base64.strict_encode64(Y.wrap_update(update))
      ::Rage.cable.broadcast(Y::ActionCable.stream_name(key), { "update" => encoded })
    end

    # Where a Rage channel differs from an Action Cable one.
    module Channel
      private

      def sync_broadcast(stream, message) = ::Rage.cable.broadcast(stream, message)

      def sync_logger = ::Rage.logger
    end
  end
end

# Under Rails the engine autoloads the models.
unless defined?(Yrby::Engine)
  require "active_record"
  require_relative "../../app/models/y/document_update"
  require_relative "../../app/models/y/document"
end
