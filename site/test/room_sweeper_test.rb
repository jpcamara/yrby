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
    # HELLO is larger than this tiny cap, so the room reads full straight from
    # the store; a long TTL means only `forget` (from the sweep) can clear it.
    Rooms.current = Rooms.new(max_document_bytes: 5, size_cache_ttl: 3600)
    make_room("tiptap/stale", age: 2.hours)

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

  test "a stale note whose document is gone is swept" do
    note = Note.create!(room: "old")
    note.update_columns(updated_at: 2.days.ago)

    assert_includes RoomSweeper.run_once(ttl: 1.day), "note:old"
    assert_not Note.exists?(room: "old")
  end

  test "a note with a live document is never swept while the document is" do
    note = Note.create!(room: "busy")
    document = note.find_or_create_collaborative_document(:body)
    note.update_columns(updated_at: 2.days.ago)

    RoomSweeper.run_once(ttl: 1.day)

    # The document is fresh (just created), so both survive: a stale-looking
    # note never takes a live document down with it.
    assert Note.exists?(room: "busy")
    assert Y::Document.exists?(key: "note/#{note.id}/body")

    # Once the document itself goes stale, one pass takes both: the document
    # sweep runs first, and the note sweep then finds the note document-less.
    document.update_columns(updated_at: 2.days.ago)
    evicted = RoomSweeper.run_once(ttl: 1.day)

    assert_includes evicted, "note/#{note.id}/body"
    assert_includes evicted, "note:busy"
    assert_not Note.exists?(room: "busy")
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
