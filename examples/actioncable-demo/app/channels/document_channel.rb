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
    on_load  { |key| AuditLog.replay(key) }
    on_change { |key, update| AuditLog.record(key, update) }
  end

  def subscribed
    sync_for params[:id]
  end

  def receive(data)
    sync_receive(data)
  end

  def unsubscribed
    sync_unsubscribed
  end
end
