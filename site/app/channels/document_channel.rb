# The collaborative document channel for the shape demos (spreadsheet,
# whiteboard, kanban, code, Tiptap).
#
# The yrby part matches the docs: `include Y::ActionCable` (through
# RoomGuarded) and two hooks that use the gem's storage models on SQLite.
# RoomGuarded adds the throttles, because these rooms are public and anonymous.
#
# Sockets terminate in the anycable-go server embedded in thrust. It calls this
# channel over HTTP RPC served by Falcon, with a new channel instance for each
# command. Params come with every call, and per-subscription state is kept with
# `state_attr_accessor` (see RoomGuarded).
class DocumentChannel < ApplicationCable::Channel
  include RoomGuarded

  # The same store the README shows. Y::Document keeps nothing important in
  # process memory. `load_state` replays the snapshot and the rows after it,
  # and `append` records one update. The gem compacts every 64 rows by default,
  # and it sets pending rows aside during compaction without dropping them.
  # RoomGuarded#refuse_write? reserves the bytes through Rooms#reserve_write
  # before the write, so this channel doesn't track sizes.
  on_load { |key| Y::Document.load_state(key) }
  on_change { |key, update| Y::Document.append(key, update) }

  def subscribed
    return reject unless authorized?
    return reject unless take_seat(key)

    sync_subscribed(key)
  end

  def unsubscribed
    release_seat(key.to_s)
  end

  def receive(data)
    guarded_receive(data, key.to_s)
  end

  private

  # sync_subscribed rejects the subscription unless this returns true.
  # `subscribed` also checks it first, so a refused client never takes a seat.
  # Access works like the Lexxy demo. The client never names a document. It
  # sends the signed grant the page rendered, and the key is whatever that
  # grant verifies to. Without a grant, nothing connects.
  def authorized?(_key = nil)
    key.present?
  end

  # Read from the token on every command. Each RPC call builds a new channel
  # instance, and verifying the signature is cheaper than storing the key as
  # channel state.
  def key
    @key ||= Demos.verified_key(params[:token])
  end
end
