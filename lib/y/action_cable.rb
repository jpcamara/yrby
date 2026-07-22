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
  end
end

require "y/action_cable/sync"
require "y/update_log"
