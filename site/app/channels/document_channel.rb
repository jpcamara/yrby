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
# command, so `params[:id]` is passed to every call and per-subscription state
# lives in `state_attr_accessor` (see RoomGuarded).
class DocumentChannel < ApplicationCable::Channel
  include RoomGuarded

  # The canonical store, verbatim from the README. Y::Document keeps nothing
  # authoritative in process memory: load replays the snapshot plus the tail,
  # append records one delta, and the gem's own compaction (every 64 rows by
  # default) folds the tail with pending rows quarantined, not dropped.
  # note_append keeps the site's size cap current without a query per frame.
  on_load { |key| Y::Document.load_state(key) }
  on_change do |key, update|
    Y::Document.append(key, update)
    Rooms.current.note_append(key, update.bytesize)
  end

  def subscribed
    key = params[:id].to_s
    return reject unless Demos.valid_key?(key)
    return reject unless take_seat(key)

    sync_subscribed(key)
  end

  def unsubscribed
    release_seat(params[:id].to_s)
  end

  def receive(data)
    guarded_receive(data, params[:id].to_s)
  end
end
