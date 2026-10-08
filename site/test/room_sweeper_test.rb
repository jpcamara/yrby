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

  test "a sweep deletes stale rooms and their rows" do
    make_room("tiptap/stale", age: 2.hours)

    assert_equal ["tiptap/stale"], RoomSweeper.run_once(ttl: 1.hour)
    assert_not Y::Document.exists?(key: "tiptap/stale")
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "a room with a recent write is kept even if the document row is old" do
    document = make_room("tiptap/active", age: 2.hours)
    # A new append. Appends don't change the document row's updated_at, so it
    # stays old, but the new update row counts as activity.
    document.updates.create!(payload: Updates::CHAIN[0])

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Y::Document.exists?(key: "tiptap/active")
  end

  test "an occupied room is kept however stale it is" do
    make_room("tiptap/quiet", age: 2.days)
    Rooms.current.join("tiptap/quiet")

    assert_empty RoomSweeper.run_once(ttl: 1.hour)
    assert Y::Document.exists?(key: "tiptap/quiet")
  end

  test "eviction clears the room's cached size" do
    # HELLO is larger than this small cap, so the room reads as full from the
    # database. With a long cache TTL, only `forget` from the sweep can clear
    # the cached size.
    Rooms.current = Rooms.new(max_document_bytes: 5, size_cache_ttl: 3600)
    make_room("tiptap/stale", age: 2.hours)

    assert Rooms.current.document_full?("tiptap/stale")

    RoomSweeper.run_once(ttl: 1.hour)

    assert_not Rooms.current.document_full?("tiptap/stale"),
               "a recreated room must not keep the deleted room's size"
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

  test "a stale note whose document is gone is swept" do
    note = Note.create!(room: "old")
    note.update_columns(updated_at: 2.days.ago)

    assert_includes RoomSweeper.run_once(ttl: 1.day), "note:old"
    assert_not Note.exists?(room: "old")
  end

  test "a note is kept while its document is fresh" do
    note = Note.create!(room: "busy")
    document = note.collaborative_document(:body).document_row
    note.update_columns(updated_at: 2.days.ago)

    RoomSweeper.run_once(ttl: 1.day)

    # The document was just created, so both are kept. A stale note doesn't
    # delete a live document.
    assert Note.exists?(room: "busy")
    assert Y::Document.exists?(key: "note/#{note.id}/body")

    # Once the document is stale, one pass deletes both. The document sweep
    # runs first, so the note sweep then finds a note with no document.
    document.update_columns(updated_at: 2.days.ago)
    evicted = RoomSweeper.run_once(ttl: 1.day)

    assert_includes evicted, "note/#{note.id}/body"
    assert_includes evicted, "note:busy"
    assert_not Note.exists?(room: "busy")
  end

  test "a stale note with no document is kept while someone is in its room" do
    note = Note.create!(room: "seated")
    note.update_columns(updated_at: 2.days.ago)
    key = Y::Document.key_for(note, :body)
    Rooms.current.join(key)

    assert_empty RoomSweeper.run_once(ttl: 1.day)
    assert Note.exists?(room: "seated"), "the room has a visitor who hasn't typed yet"

    Rooms.current.leave(key)

    assert_includes RoomSweeper.run_once(ttl: 1.day), "note:seated"
    assert_not Note.exists?(room: "seated")
  end

  test "a fresh note is not swept" do
    Note.create!(room: "new")

    assert_empty RoomSweeper.run_once(ttl: 1.day)
    assert Note.exists?(room: "new")
  end

  test "the sweeper thread starts once and can be stopped" do
    thread = RoomSweeper.start(interval: 60)

    assert_predicate thread, :alive?
    assert_same thread, RoomSweeper.start(interval: 60)
  ensure
    RoomSweeper.stop
  end
end
