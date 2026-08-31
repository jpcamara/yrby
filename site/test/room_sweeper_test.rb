require "test_helper"

class RoomSweeperTest < ActiveSupport::TestCase
  test "a sweep drops idle rooms and reports them" do
    store = RoomStore.new(idle_ttl: 0)
    store.append("tiptap/gone", Updates::HELLO)

    assert_equal ["tiptap/gone"], RoomSweeper.run_once(store)
    assert_equal 0, store.live_rooms
  end

  test "a failing sweep is logged and does not raise" do
    broken = Object.new
    def broken.sweep(*) = raise("store is on fire")

    assert_equal [], RoomSweeper.run_once(broken)
  end

  test "the sweeper thread starts once and can be stopped" do
    store = RoomStore.new(idle_ttl: 0)
    thread = RoomSweeper.start(store: store, interval: 60)

    assert_predicate thread, :alive?
    assert_same thread, RoomSweeper.start(store: store, interval: 60)
  ensure
    RoomSweeper.stop
  end
end
