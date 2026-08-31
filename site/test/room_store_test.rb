require "test_helper"

class RoomStoreTest < ActiveSupport::TestCase
  KEY = "tiptap/room1".freeze

  def state_of(update)
    doc = Y::Doc.new
    doc.apply_update(update)
    doc
  end

  test "an unknown room loads as nil, which is a fresh document" do
    assert_nil RoomStore.new.load("tiptap/nobody")
  end

  test "an appended update comes back out of load" do
    store = RoomStore.new
    store.append(KEY, Updates::HELLO)

    assert_equal "hello world", state_of(store.load(KEY)).read_text("content")
  end

  test "appends replay in order into one document" do
    store = RoomStore.new
    Updates::CHAIN.each { |update| store.append(KEY, update) }

    assert_equal "ABC", state_of(store.load(KEY)).read_text("content")
  end

  test "compaction folds the tail and the document survives it" do
    store = RoomStore.new(compact_every: 3)
    Updates::INDEPENDENT.each { |update| store.append(KEY, update) }

    # Five appends with compact_every 3: the tail folded at least once, so the
    # bytes held are less than the sum of what was written.
    assert_operator store.bytes(KEY), :<, Updates::INDEPENDENT.sum(&:bytesize)

    text = state_of(store.load(KEY)).read_text("content")

    (1..5).each { |i| assert_includes text, "client-#{i}-content" }
  end

  test "compaction is skipped while the document holds a causal gap" do
    store = RoomStore.new(compact_every: 2)
    # U1 then U3: U3 depends on U2, which never arrives, so it parks as pending.
    store.append(KEY, Updates::CHAIN[0])
    store.append(KEY, Updates::CHAIN[2])

    assert_predicate state_of(store.load(KEY)), :pending?, "the loaded state should still carry the gap"

    # The missing update lands and the document heals, pending and all.
    store.append(KEY, Updates::CHAIN[1])
    doc = state_of(store.load(KEY))

    assert_not doc.pending?
    assert_equal "ABC", doc.read_text("content")
  end

  test "a room at its byte cap refuses further appends" do
    store = RoomStore.new(max_document_bytes: Updates::HELLO.bytesize)
    store.append(KEY, Updates::HELLO)

    assert store.full?(KEY)
    assert_raises(RoomStore::DocumentFull) { store.append(KEY, Updates::HELLO) }
    # What was already recorded is still readable.
    assert_equal "hello world", state_of(store.load(KEY)).read_text("content")
  end

  test "a room under its byte cap is not full" do
    store = RoomStore.new(max_document_bytes: 10_000)
    store.append(KEY, Updates::HELLO)

    assert_not store.full?(KEY)
  end

  test "peers per room are capped" do
    store = RoomStore.new(max_peers: 2)

    assert_equal :ok, store.join(KEY)
    assert_equal :ok, store.join(KEY)
    assert_equal :room_full, store.join(KEY)
    assert_equal 2, store.peers(KEY)

    store.leave(KEY)

    assert_equal :ok, store.join(KEY)
  end

  test "leaving never drives the peer count below zero" do
    store = RoomStore.new
    3.times { store.leave(KEY) }

    assert_equal 0, store.peers(KEY)
  end

  test "live rooms are capped process-wide" do
    store = RoomStore.new(max_rooms: 2)

    assert_equal :ok, store.join("tiptap/a")
    assert_equal :ok, store.join("tiptap/b")
    assert_equal :too_many_rooms, store.join("tiptap/c")
    assert_equal 2, store.live_rooms

    # An existing room still admits people once the process is at the cap.
    assert_equal :ok, store.join("tiptap/a")
  end

  test "a write to a new room is refused once the process is at the room cap" do
    store = RoomStore.new(max_rooms: 1)
    store.join("tiptap/a")

    assert_raises(RoomStore::DocumentFull) { store.append("tiptap/b", Updates::HELLO) }
  end

  test "idle empty rooms are evicted and occupied ones are not" do
    store = RoomStore.new(idle_ttl: 60)
    store.join("tiptap/occupied")
    store.append("tiptap/abandoned", Updates::HELLO)

    assert_empty store.sweep, "nothing is idle yet"

    later = RoomStore.now + 61

    assert_equal ["tiptap/abandoned"], store.sweep(later)
    assert_equal 1, store.live_rooms
    assert_nil store.load("tiptap/abandoned")
  end

  test "an evicted room loads as fresh, so a reconnecting client re-seeds it" do
    store = RoomStore.new(idle_ttl: 0)
    store.append(KEY, Updates::HELLO)
    store.sweep

    assert_nil store.load(KEY)

    store.append(KEY, Updates::HELLO)

    assert_equal "hello world", state_of(store.load(KEY)).read_text("content")
  end

  test "reading and appending from many threads converges" do
    store = RoomStore.new
    threads = Updates::INDEPENDENT.map do |update|
      Thread.new do
        10.times do
          store.append(KEY, update)
          store.load(KEY)
        end
      end
    end
    threads.each(&:join)

    text = state_of(store.load(KEY)).read_text("content")

    (1..5).each { |i| assert_includes text, "client-#{i}-content" }
  end
end
