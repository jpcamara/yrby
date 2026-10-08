require "test_helper"

# The site's limits on top of the Y::Document store: seats, room count, the
# document size cap, and the eviction steps the sweeper uses. The gem tests the
# store itself (load and append, compaction, pending updates). These tests
# cover what the site adds.
class RoomsTest < ActiveSupport::TestCase
  KEY = "tiptap/room1".freeze

  test "the channel hooks save and load a document in SQLite" do
    # The same store calls the channel makes, against the real models.
    assert_nil Y::Document.load_state(KEY)

    Y::Document.append(KEY, Updates::HELLO)
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state(KEY))

    assert_equal "hello world", doc.read_text("content")
  end

  test "appends replay in order into one document" do
    Updates::CHAIN.each { |update| Y::Document.append(KEY, update) }
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state(KEY))

    assert_equal "ABC", doc.read_text("content")
  end

  test "a missing dependency is kept as pending until it arrives" do
    # U1 then U3, and U3 depends on U2. load_state keeps everything, so U3 is
    # kept as a pending struct and applies once U2 is appended.
    Y::Document.append(KEY, Updates::CHAIN[0])
    Y::Document.append(KEY, Updates::CHAIN[2])
    parked = Y::Doc.new
    parked.apply_update(Y::Document.load_state(KEY))

    assert_predicate parked, :pending?

    Y::Document.append(KEY, Updates::CHAIN[1])
    healed = Y::Doc.new
    healed.apply_update(Y::Document.load_state(KEY))

    assert_not healed.pending?
    assert_equal "ABC", healed.read_text("content")
  end

  test "peers per room are capped" do
    rooms = Rooms.new(max_peers: 2)

    assert_equal :ok, rooms.join(KEY)
    assert_equal :ok, rooms.join(KEY)
    assert_equal :room_full, rooms.join(KEY)
    assert_equal 2, rooms.peers(KEY)

    rooms.leave(KEY)

    assert_equal :ok, rooms.join(KEY)
  end

  test "leaving keeps the peer count at zero or above" do
    rooms = Rooms.new
    3.times { rooms.leave(KEY) }

    assert_equal 0, rooms.peers(KEY)
  end

  test "the room cap counts saved documents" do
    rooms = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO)

    assert_equal :too_many_rooms, rooms.join(KEY)
    # A room whose document already exists is not a new room.
    assert_equal :ok, rooms.join("tiptap/taken")
  end

  test "pending reservations count toward the room cap before any append" do
    # Many subscribes to different valid keys, none with a document yet.
    # Without reservations, the saved count would still be 0, so every one
    # would be let in and then create a row.
    rooms = Rooms.new(max_rooms: 2)

    assert_equal :ok, rooms.join("tiptap/a")
    assert_equal :ok, rooms.join("tiptap/b")
    assert_equal :too_many_rooms, rooms.join("tiptap/c"),
                 "two seated rooms with no writes already fill a cap of two"
  end

  test "a reservation is released when its last occupant leaves" do
    rooms = Rooms.new(max_rooms: 1)

    assert_equal :ok, rooms.join("tiptap/a")
    assert_equal :too_many_rooms, rooms.join("tiptap/b")

    rooms.leave("tiptap/a") # never wrote a document, so the reservation is freed

    assert_equal :ok, rooms.join("tiptap/b")
  end

  test "a reservation is released once the room's document is written" do
    rooms = Rooms.new(max_rooms: 1)

    assert_equal :ok, rooms.join("tiptap/a") # reserves the one slot
    rooms.reserve_write("tiptap/a", 10)      # first write, so it counts as a saved row
    Y::Document.append("tiptap/a", Updates::HELLO)

    # The reservation is now a saved row. The cap is still 1 and that row
    # exists, so a new room is refused.
    assert_equal :too_many_rooms, rooms.join("tiptap/b")
    # The saved room still lets in a second peer.
    assert_equal :ok, rooms.join("tiptap/a")
  end

  test "a second seat in a room with no writes yet is not blocked by the room cap" do
    rooms = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO)

    # The first visitor got a seat before the cap was reached. A peer joining
    # them must not be refused as a new room.
    rooms.instance_variable_get(:@seats)[KEY] = 1

    assert_equal :ok, rooms.join(KEY)
  end

  test "a room at its byte cap reads as full" do
    rooms = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)

    assert_not rooms.document_full?(KEY), "an empty room is not full"

    assert rooms.reserve_write(KEY, Updates::HELLO.bytesize)
    assert rooms.document_full?(KEY)
  end

  test "reserve_write refuses the write that would go over the cap" do
    rooms = Rooms.new(max_document_bytes: 100)

    assert rooms.reserve_write(KEY, 60), "60 of 100 fits"
    assert_not rooms.reserve_write(KEY, 50), "60 + 50 is over the cap and is refused"
    assert rooms.reserve_write(KEY, 40), "60 + 40 exactly reaches the cap and fits"
    assert_not rooms.reserve_write(KEY, 1), "the room is full"
  end

  test "reserve_write keeps the cap tight without waiting for the cache to expire" do
    # With a long TTL, only reserve_write changes the cached size.
    rooms = Rooms.new(max_document_bytes: 100, size_cache_ttl: 3600)

    assert_not rooms.document_full?(KEY) # primes the cache at 0

    assert rooms.reserve_write(KEY, 100)
    assert rooms.document_full?(KEY), "the reservation alone fills the room before the TTL expires"
  end

  test "forget clears the cached size so a deleted room starts from zero" do
    rooms = Rooms.new(max_document_bytes: 100, size_cache_ttl: 3600)
    rooms.reserve_write(KEY, 100) # fills the room to its cap

    assert rooms.document_full?(KEY)

    rooms.forget(KEY)

    assert_not rooms.document_full?(KEY), "after deletion the room starts empty"
  end

  test "the size query counts the snapshot and the update rows" do
    rooms = Rooms.new(size_cache_ttl: 0)
    Updates::INDEPENDENT.each { |update| Y::Document.append(KEY, update) }
    expected = Updates::INDEPENDENT.sum(&:bytesize)

    assert_equal expected, rooms.send(:query_size, KEY)
  end

  test "room_available? counts saved rows and live reservations against the cap" do
    rooms = Rooms.new(max_rooms: 2)

    assert_predicate rooms, :room_available?, "empty, under the cap"

    rooms.join("tiptap/a") # one reservation

    assert_predicate rooms, :room_available?, "one of two used"

    Y::Document.append("tiptap/b", Updates::HELLO) # one persisted row

    assert_not rooms.room_available?, "one saved and one reserved fill a cap of two"
  end

  test "occupied_keys lists rooms with someone in them" do
    rooms = Rooms.new
    rooms.join("tiptap/a")
    rooms.join("kanban/b")
    rooms.leave("tiptap/a")

    assert_equal ["kanban/b"], rooms.occupied_keys
  end

  # --- eviction coordination (see RoomSweeper) --------------------------------

  test "claim_evictions marks unoccupied, unreserved candidates" do
    rooms = Rooms.new
    Y::Document.append("tiptap/idle", Updates::HELLO)

    assert_equal ["tiptap/idle"], rooms.claim_evictions(["tiptap/idle"])
    assert rooms.evicting?("tiptap/idle")
  end

  test "claim_evictions skips an occupied room" do
    rooms = Rooms.new
    Y::Document.append("tiptap/busy", Updates::HELLO)
    rooms.join("tiptap/busy")

    assert_empty rooms.claim_evictions(["tiptap/busy"])
    assert_not rooms.evicting?("tiptap/busy")
  end

  test "claim_evictions skips a reserved room" do
    rooms = Rooms.new
    rooms.join("tiptap/pending") # reserved, not yet written

    assert_empty rooms.claim_evictions(["tiptap/pending"])
  end

  test "a join for an evicting key is refused" do
    rooms = Rooms.new
    Y::Document.append("tiptap/going", Updates::HELLO)
    rooms.claim_evictions(["tiptap/going"])

    assert_equal :evicting, rooms.join("tiptap/going")
  end

  test "forget clears the evicting mark so a kept room can be joined again" do
    rooms = Rooms.new
    Y::Document.append("tiptap/spared", Updates::HELLO)
    rooms.claim_evictions(["tiptap/spared"])
    rooms.forget("tiptap/spared") # the sweeper kept it after reading the database again

    assert_not rooms.evicting?("tiptap/spared")
    assert_equal :ok, rooms.join("tiptap/spared")
  end
end
