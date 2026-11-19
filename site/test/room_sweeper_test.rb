require "test_helper"

class RoomSweeperTest < ActiveSupport::TestCase
  def make_room(slug, age:)
    room = Room.create!(slug:)
    room.update_columns(created_at: age.ago, updated_at: age.ago)
    room
  end

  # A document for `room`'s `name`, written and last touched `age` ago.
  def make_document(room, name, age:)
    room.collaborative_document(name).append(Updates::HELLO)
    document = Y::Document.find_by!(record: room, name: name.to_s)
    stamp = age.ago
    document.update_columns(created_at: stamp, updated_at: stamp)
    document.updates.update_all(created_at: stamp)
    document
  end

  test "a sweep deletes a stale document and then its empty room" do
    room = make_room("stale", age: 2.hours)
    document = make_document(room, :tiptap, age: 2.hours)

    assert_equal [document.key, "room:stale"], RoomSweeper.run_once(ttl: 1.hour)
    assert_not Room.exists?(slug: "stale")
    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "a document with a recent write is kept even if its row is old" do
    room = make_room("active", age: 2.hours)
    document = make_document(room, :tiptap, age: 2.hours)
    # A new append. Appends don't change the document row's updated_at, so it
    # stays old, but the new update row counts as activity.
    document.updates.create!(payload: Updates::CHAIN[0])

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Room.exists?(slug: "active")
  end

  test "a stale document someone is seated in is kept, and so is its room" do
    room = make_room("quiet", age: 2.days)
    make_document(room, :tiptap, age: 2.days)
    Rooms.current.join(room, "tiptap", "c1")

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Y::Document.exists?(record: room, name: "tiptap")
    assert Room.exists?(slug: "quiet")
  end

  test "a seat in one document doesn't keep another stale document" do
    room = make_room("mixed", age: 2.days)
    stale = make_document(room, :kanban, age: 2.days)
    Rooms.current.join(room, "tiptap", "c1")

    assert_equal [stale.key], RoomSweeper.run_once(ttl: 1.hour)
    assert Room.exists?(slug: "mixed"), "the room has a visitor"
  end

  test "a stale room with nobody in it and no documents is swept" do
    make_room("empty", age: 2.days)

    assert_equal ["room:empty"], RoomSweeper.run_once(ttl: 1.day)
  end

  test "a swept room's Action Text body goes with it" do
    room = make_room("lexxy", age: 2.days)
    ActionText::RichText.create!(record: room, name: "body", body: "<p>hi</p>")
    room.update_columns(updated_at: 2.days.ago) # the body's save touched the room
    kept = Room.create!(slug: "kept", body: "<p>kept</p>")

    assert_equal ["room:lexxy"], RoomSweeper.run_once(ttl: 1.day)
    assert_equal [kept.id], ActionText::RichText.pluck(:record_id)
  end

  test "a stale room is kept while someone is in it" do
    room = make_room("seated", age: 2.days)
    Rooms.current.join(room, "body", "c1")

    assert_empty RoomSweeper.run_once(ttl: 1.day), "the room has a visitor who hasn't typed yet"

    Rooms.current.leave(room, "body", "c1")

    assert_equal ["room:seated"], RoomSweeper.run_once(ttl: 1.day)
  end

  test "a fresh room is not swept" do
    Room.create!(slug: "new")

    assert_empty RoomSweeper.run_once(ttl: 1.day)
  end

  test "a document from before rooms had rows goes after the TTL" do
    Y::Document.append("tiptap/old", Updates::HELLO)
    document = Y::Document.find_by!(key: "tiptap/old")
    document.update_columns(updated_at: 2.days.ago)
    document.updates.update_all(created_at: 2.days.ago)

    assert_equal ["tiptap/old"], RoomSweeper.run_once(ttl: 1.day)
  end

  test "leaked seats are deleted, which frees their room" do
    room = make_room("leaked", age: 2.days)
    Rooms.current.join(room, "tiptap", "gone")
    Seat.update_all(seen_at: (Limits::SEAT_TTL + 60).seconds.ago)

    assert_equal ["room:leaked"], RoomSweeper.run_once(ttl: 1.day)
    assert_equal 0, Seat.count
  end

  test "a seat seen recently is kept" do
    room = make_room("live", age: 2.days)
    Rooms.current.join(room, "tiptap", "here")

    RoomSweeper.run_once(ttl: 1.day)

    assert_equal 1, Seat.count
  end

  test "eviction clears the document's cached size" do
    # HELLO is larger than this small cap, so the document reads as full from
    # the database. With a long cache TTL, only `forget` from the sweep can
    # clear the cached size.
    Rooms.current = Rooms.new(max_document_bytes: 5, size_cache_ttl: 3600)
    document = make_document(make_room("stale", age: 2.hours), :tiptap, age: 2.hours)

    assert Rooms.current.document_full?(document.key)

    RoomSweeper.run_once(ttl: 1.hour)

    assert_not Rooms.current.document_full?(document.key),
               "a recreated document must not keep the deleted one's size"
  end

  test "a failing sweep is logged and does not raise" do
    broken = Object.new
    def broken.forget(_key) = raise("sizes are on fire")
    make_document(make_room("stale", age: 2.hours), :tiptap, age: 2.hours)

    assert_equal [], RoomSweeper.run_once(rooms: broken, ttl: 1.hour)
  end

  test "the sweeper thread starts once and can be stopped" do
    thread = RoomSweeper.start(interval: 60)

    assert_predicate thread, :alive?
    assert_same thread, RoomSweeper.start(interval: 60)
  ensure
    RoomSweeper.stop
  end
end
