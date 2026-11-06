require "test_helper"

# The site's limits on top of the Y::Document store: starting rooms, seats,
# and the document size cap. The gem tests the store itself (load and append,
# compaction, pending updates). These tests cover what the site adds.
class RoomsTest < ActiveSupport::TestCase
  KEY = "tiptap/room1".freeze

  setup { @room = Room.create!(slug: "room1") }

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

  test "start creates a room once and returns it after" do
    rooms = Rooms.new

    started = rooms.start("fresh")

    assert_equal "fresh", started.slug
    assert_equal started, rooms.start("fresh")
  end

  test "start refuses a new room at the room cap and still returns an existing one" do
    rooms = Rooms.new(max_rooms: 1) # @room fills it

    assert_nil rooms.start("another")
    assert_equal @room, rooms.start("room1")
    assert_equal 1, Room.count
  end

  test "peers per document are capped" do
    rooms = Rooms.new(max_peers: 2)

    assert_equal :ok, rooms.join(@room, "tiptap", "c1")
    assert_equal :ok, rooms.join(@room, "tiptap", "c2")
    assert_equal :room_full, rooms.join(@room, "tiptap", "c3")
    assert_equal 2, rooms.peers(@room, "tiptap")
    assert_equal :ok, rooms.join(@room, "kanban", "c3"), "each document has its own peers"

    rooms.leave(@room, "tiptap", "c1")

    assert_equal :ok, rooms.join(@room, "tiptap", "c3")
  end

  test "a connection holds one seat per document" do
    rooms = Rooms.new

    assert_equal :ok, rooms.join(@room, "tiptap", "c1")
    assert_equal :duplicate, rooms.join(@room, "tiptap", "c1")

    rooms.leave(@room, "tiptap", "c1")

    assert_equal :ok, rooms.join(@room, "tiptap", "c1"), "rejoining after leaving works"
  end

  # Seats are rows, so a join one process handles and a leave another handles
  # meet. Two Rooms objects stand in for two processes.
  test "seats are shared by every process" do
    web1 = Rooms.new(max_peers: 1)
    web2 = Rooms.new(max_peers: 1)

    assert_equal :ok, web1.join(@room, "tiptap", "c1")
    assert_equal :room_full, web2.join(@room, "tiptap", "c2")
    assert_equal :duplicate, web2.join(@room, "tiptap", "c1")

    web2.leave(@room, "tiptap", "c1")

    assert_equal :ok, web1.join(@room, "tiptap", "c2")
  end

  test "a connection's subscriptions are capped" do
    rooms = Rooms.new(max_subscriptions: 2)

    assert_equal :ok, rooms.join(@room, "tiptap", "c1")
    assert_equal :ok, rooms.join(@room, "kanban", "c1")
    assert_equal :too_many, rooms.join(@room, "chat", "c1")
    assert_equal :ok, rooms.join(@room, "chat", "c2"), "the cap is per connection"
  end

  test "a join to a deleted room is refused" do
    rooms = Rooms.new
    Room.where(id: @room.id).delete_all

    assert_equal :gone, rooms.join(@room, "tiptap", "c1")
    assert_equal 0, Seat.count
  end

  test "leave_all gives back every seat a connection holds" do
    rooms = Rooms.new
    rooms.join(@room, "tiptap", "c1")
    rooms.join(@room, "kanban", "c1")
    rooms.join(@room, "kanban", "c2")

    rooms.leave_all("c1")

    assert_equal 0, rooms.peers(@room, "tiptap")
    assert_equal 1, rooms.peers(@room, "kanban")
  end

  test "seen refreshes a connection's seats" do
    rooms = Rooms.new
    rooms.join(@room, "tiptap", "c1")
    rooms.join(@room, "kanban", "c2")
    Seat.update_all(seen_at: 1.hour.ago)

    rooms.seen("c1")

    assert_operator Seat.find_by!(connection_id: "c1").seen_at, :>, 1.minute.ago
    assert_operator Seat.find_by!(connection_id: "c2").seen_at, :<, 1.minute.ago
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

  test "forget clears the cached size so a deleted document starts from zero" do
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
end
