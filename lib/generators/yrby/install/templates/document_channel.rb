# frozen_string_literal: true

# Collaborative documents over Action Cable: one channel speaking the
# y-websocket protocol (sync plus presence). Storage is Y::Document +
# Y::DocumentUpdate; a document is created on its first change and its
# history goes with it when it is destroyed. Point on_load/on_change
# elsewhere to swap storage.
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  # Rebuild a document from durable storage (nil means a brand-new document).
  on_load { |key| Y::Document.load_state(key) }

  # Record each CRDT delta durably. Runs before the change is acknowledged
  # or broadcast; raising rejects the change and the client retransmits.
  on_change { |key, update| Y::Document.append(key, update) }

  def subscribed
    return reject unless authorized?(params[:id])

    sync_subscribed(params[:id])
  end

  def receive(data) = sync_receive(data, params[:id])

  private

  # Everyone is denied until you fill this in. Wire it to your app's auth:
  # identify current_user on the cable connection, then check they may read
  # and write this document. Don't lean on on_change raising for access
  # control — that path exists for store failures.
  def authorized?(_document_key)
    false
  end
end
