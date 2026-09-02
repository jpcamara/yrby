# The collaborative document channel behind the shape demos (spreadsheet,
# whiteboard, kanban, code, Tiptap).
#
# The yrby half is exactly what the docs teach: `include Y::ActionCable` (via
# RoomGuarded) and the two hooks pointed at the gem's own storage models on
# SQLite. RoomGuarded carries the throttle layers, because these rooms are
# public and anonymous.
#
# Sockets terminate in the anycable-go embedded in thrust, which calls this
# channel over HTTP RPC served by Falcon — a fresh channel instance per
# command, so params ride along on every call and per-subscription state
# lives in `state_attr_accessor` (see RoomGuarded).
class DocumentChannel < ApplicationCable::Channel
  include RoomGuarded

  # The canonical store, verbatim from the README. Y::Document keeps nothing
  # authoritative in process memory: load replays the snapshot plus the tail,
  # append records one delta, and the gem's own compaction (every 64 rows by
  # default) folds the tail with pending rows quarantined, not dropped. The
  # site's size cap is charged before the write (RoomGuarded#refuse_write?
  # reserves the bytes through Rooms#reserve_write), so there is no size
  # bookkeeping to do here.
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

  # The gem's fail-closed seam (sync_subscribed rejects unless this returns
  # true; subscribed also asks first, so a refused client never takes a seat).
  # The access model is the Lexxy demo's: clients never name a document;
  # they present the signed grant the page rendered, and the key is whatever
  # that token verifies to. Nothing connects without one.
  def authorized?(_key = nil)
    key.present?
  end

  # Derived from the token on every command — each RPC call builds a fresh
  # channel instance, and verifying the signature is cheaper than carrying the
  # key as channel state.
  def key
    @key ||= Demos.verified_key(params[:token])
  end
end
