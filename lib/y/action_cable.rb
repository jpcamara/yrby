# frozen_string_literal: true

require "y"

module Y
  # ActionCable integration for yrby.
  #
  # Provides Y::ActionCable::Sync, a channel concern implementing the
  # y-websocket sync protocol and awareness/presence over ActionCable (and
  # AnyCable), so a Rails app can be the collaboration server for Y.js editors
  # with no Node sidecar. The CRDT documents, awareness, and protocol primitives
  # themselves come from the core `yrby` gem.
  module ActionCable
    # `include Y::ActionCable` forwards to `Y::ActionCable::Sync`, the
    # module's home. Both spellings work; the short one reads better in a
    # channel.
    def self.included(base)
      base.include(Sync)
    end

    # The stream a document's subscribers listen on.
    def self.stream_name(key) = "yrby:#{key}"

    # Sends an update to everyone subscribed to a document, from outside a
    # channel: a job, a console, or Y::Collaborative::Attribute#edit. Record
    # the update first. This only distributes it.
    def self.broadcast(key, update)
      encoded = Base64.strict_encode64(Y.wrap_update(update))
      ::ActionCable.server.broadcast(stream_name(key), { "update" => encoded })
    end
  end
end

require "y/action_cable/sync"
