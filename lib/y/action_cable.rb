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

    # Send a document update to everyone subscribed to a document, from
    # outside a channel. The update must already be recorded: this only
    # distributes it. It is what Y::Collaborative::Attribute#edit calls after
    # it persists, and the way a background job or an agent gets its edits
    # onto screens.
    #
    # `update` is raw Yjs update bytes. Clients read every frame's first byte
    # as its y-protocol message type, so the update is framed as a sync
    # message here. Sending the bytes bare would be misread as presence.
    def self.broadcast(key, update)
      broadcast_frame(key, Y.wrap_update(update))
    end

    # Relay a presence frame, such as one from Y::Awareness#set_local_state.
    # It is already a complete y-protocol message, so it goes out as is.
    def self.broadcast_awareness(key, frame)
      broadcast_frame(key, frame)
    end

    def self.broadcast_frame(key, frame)
      ::ActionCable.server.broadcast(Sync.stream_name(key), Sync.envelope(Base64.strict_encode64(frame)))
    end
    private_class_method :broadcast_frame
  end
end

require "y/action_cable/sync"
require "y/action_cable/peer"
