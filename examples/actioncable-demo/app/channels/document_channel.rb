# frozen_string_literal: true

# Collaborative document channel — the whole y-websocket protocol is three
# lines thanks to YrbLite::Sync. Documents live in memory; add on_load /
# on_save callbacks to persist them.
class DocumentChannel < ApplicationCable::Channel
  include YrbLite::Sync

  # Opt-in authoritative audit mode (AUDIT=1): record every change durably,
  # in a single total order, BEFORE it is applied or broadcast. Without this
  # the channel uses the default fast path.
  #
  # on_load rebuilds a document from its audit log, so a document survives an
  # eviction *or a server crash* — the fsync'd log is the source of truth.
  if ENV["AUDIT"].present?
    on_load  { |key| Store.current.replay(key) }
    on_change { |key, update| Store.current.record(key, update) }
  end

  # SYNC_BACKEND=store uses the stateless, store-backed path (works under
  # AnyCable and across processes with no worker affinity). Requires the
  # on_load/on_change store above.
  sync_backend(ENV["SYNC_BACKEND"].to_sym) if ENV["SYNC_BACKEND"].present?

  # Pass params[:id] on every action so the channel works under AnyCable too,
  # where each RPC command gets a fresh channel instance (no ivars persist).
  def subscribed
    sync_for params[:id]
  end

  def receive(data)
    sync_receive(data, params[:id])
  end

  def unsubscribed
    sync_unsubscribed(params[:id])
  end
end
