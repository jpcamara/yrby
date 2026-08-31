require "test_helper"

class RoomSweeperTest < ActiveSupport::TestCase
  def make_room(key, age:)
    Y::Document.append(key, Updates::HELLO)
    document = Y::Document.find_by!(key: key)
    stamp = Time.current - age
    document.update_columns(created_at: stamp, updated_at: stamp)
    document.updates.update_all(created_at: stamp)
    document
  end

  test "a sweep deletes stale rooms, rows and all" do
    make_room("tiptap/stale", age: 2.hours)

    assert_equal ["tiptap/stale"], RoomSweeper.run_once(ttl: 1.hour)
    assert_not Y::Document.exists?(key: "tiptap/stale")
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "a room with a recent write is kept even if the document row is old" do
    document = make_room("tiptap/active", age: 2.hours)
    # A new append: the document row's updated_at stays old (appends don't
    # touch it), but the update row is fresh — that must count as activity.
    document.updates.create!(payload: Updates::CHAIN[0])

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Y::Document.exists?(key: "tiptap/active")
  end

  test "an occupied room is never evicted, however stale" do
    make_room("tiptap/quiet", age: 2.days)
    Rooms.current.join("tiptap/quiet")

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Y::Document.exists?(key: "tiptap/quiet")
  end

  test "eviction clears the room's cached size" do
    Rooms.current = Rooms.new(max_document_bytes: 10, size_cache_ttl: 3600)
    make_room("tiptap/stale", age: 2.hours)
    Rooms.current.document_full?("tiptap/stale")
    Rooms.current.note_append("tiptap/stale", 100)

    assert Rooms.current.document_full?("tiptap/stale")

    RoomSweeper.run_once(ttl: 1.hour)

    assert_not Rooms.current.document_full?("tiptap/stale"),
               "a re-created room must not inherit the evicted room's size"
  end

  test "a fresh room is not swept" do
    Y::Document.append("tiptap/new", Updates::HELLO)

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
  end

  test "a failing sweep is logged and does not raise" do
    broken = Object.new
    def broken.occupied_keys = raise("seats are on fire")

    assert_equal [], RoomSweeper.run_once(rooms: broken)
  end

  test "the sweeper thread starts once and can be stopped" do
    thread = RoomSweeper.start(interval: 60)

    assert_predicate thread, :alive?
    assert_same thread, RoomSweeper.start(interval: 60)
  ensure
    RoomSweeper.stop
  end
end
