require "test_helper"

# The site's caps around the Y::Document store: seats, room count, and the
# document size cap. The store itself (load/append round-trip, compaction,
# pending quarantine) is the gem's own, tested in the gem; these tests cover
# what the site adds on top.
class RoomsTest < ActiveSupport::TestCase
  KEY = "tiptap/room1".freeze

  test "the canonical hooks round-trip a document through SQLite" do
    # The exact store calls the channel makes, against the real models.
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

  test "a causal gap is preserved across the store and heals" do
    # U1 then U3: U3 depends on U2. load_state is lossless, so the gap rides
    # along as a pending struct and heals when U2 lands.
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

  test "leaving never drives the peer count below zero" do
    rooms = Rooms.new
    3.times { rooms.leave(KEY) }

    assert_equal 0, rooms.peers(KEY)
  end

  test "documents on disk are capped" do
    rooms = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO)

    assert_equal :too_many_rooms, rooms.join(KEY)
    # A room whose document already exists is not a new room.
    assert_equal :ok, rooms.join("tiptap/taken")
  end

  test "a second seat in a not-yet-written room is not blocked by the room cap" do
    rooms = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO)

    # The first visitor was seated before the cap was reached; a peer joining
    # them must not be refused as a "new room".
    rooms.instance_variable_get(:@seats)[KEY] = 1

    assert_equal :ok, rooms.join(KEY)
  end

  test "a room at its byte cap reads as full" do
    rooms = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)

    assert_not rooms.document_full?(KEY), "an empty room is not full"

    Y::Document.append(KEY, Updates::HELLO)
    rooms.note_append(KEY, Updates::HELLO.bytesize)

    assert rooms.document_full?(KEY)
  end

  test "note_append keeps the cap tight without waiting for the cache to expire" do
    # A long TTL: only note_append can move the cached size.
    rooms = Rooms.new(max_document_bytes: 100, size_cache_ttl: 3600)

    assert_not rooms.document_full?(KEY) # primes the cache at 0

    rooms.note_append(KEY, 100)

    assert rooms.document_full?(KEY), "the cap must trip from notes alone, mid-TTL"
  end

  test "forget clears the cached size so an evicted room starts from zero" do
    rooms = Rooms.new(max_document_bytes: 10, size_cache_ttl: 3600)
    rooms.document_full?(KEY)
    rooms.note_append(KEY, 100)

    assert rooms.document_full?(KEY)

    rooms.forget(KEY)

    assert_not rooms.document_full?(KEY), "after eviction the room is fresh"
  end

  test "the size query counts snapshot plus tail" do
    rooms = Rooms.new(size_cache_ttl: 0)
    Updates::INDEPENDENT.each { |update| Y::Document.append(KEY, update) }
    expected = Updates::INDEPENDENT.sum(&:bytesize)

    assert_equal expected, rooms.send(:query_size, KEY)
  end

  test "occupied_keys lists rooms with someone in them" do
    rooms = Rooms.new
    rooms.join("tiptap/a")
    rooms.join("kanban/b")
    rooms.leave("tiptap/a")

    assert_equal ["kanban/b"], rooms.occupied_keys
  end
end
