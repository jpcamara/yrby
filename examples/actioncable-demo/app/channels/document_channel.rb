# frozen_string_literal: true

# Collaborative document channel. The whole y-websocket protocol is the three
# lines of Y::ActionCable::Sync below. Documents are loaded from and
# recorded to Store.current; ActionCable process memory is not authoritative.
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable::Sync

  on_load  { |key| Store.current.replay(key) }
  on_change do |key, update|
    Store.current.record(key, update)
    # Derived state follows the writes: re-arm the ActionText materializer
    # (trailing debounce; renders server-side once the doc goes quiet).
    # schedule never raises — a raise here would reject the change.
    NoteMaterializer.schedule(key)
  end

  # Pass params[:id] on every action so the channel works under AnyCable too,
  # where each RPC command gets a fresh channel instance (no ivars persist).
  def subscribed
    sync_subscribed params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end
end
