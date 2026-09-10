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

    # Send an update to everyone subscribed to a document, from outside a
    # channel. The update must already be recorded: this only distributes it.
    # It is what Y::Collaborative::Attribute#edit calls after it persists, and
    # the way a background job or an agent gets its edits onto screens.
    def self.broadcast(key, update)
      ::ActionCable.server.broadcast(Sync.stream_name(key), Sync.envelope(Base64.strict_encode64(update)))
    end
  end
end

require "y/action_cable/sync"
