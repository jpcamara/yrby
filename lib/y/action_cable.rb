# frozen_string_literal: true

require "y"
require "y/action_cable/version"

module Y
  # ActionCable integration for yrby.
  #
  # Provides Y::ActionCable::Sync, a channel concern implementing the
  # y-websocket sync protocol and awareness/presence over ActionCable (and
  # AnyCable), so a Rails app can be the collaboration server for Y.js editors
  # with no Node sidecar. The CRDT documents, awareness, and protocol primitives
  # themselves come from the core `yrby` gem.
  module ActionCable
    # `include Y::ActionCable` is the channel integration. Sync remains the
    # module's real home (and the long-standing spelling — both work); this
    # hook just forwards, so the include reads as "this channel is the
    # ActionCable adapter" without a redundant suffix.
    def self.included(base)
      base.include(Sync)
    end
  end
end

require "y/action_cable/sync"
require "y/update_log"
