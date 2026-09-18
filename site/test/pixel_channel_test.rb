require "test_helper"

# DocumentChannel's guards and grant, with the update log kept whole.
class PixelChannelTest < ActionCable::Channel::TestCase
  tests PixelChannel

  KEY = "pixels/room1".freeze

  setup { stub_connection(connection_id: "c1") }

  def acks = transmissions.filter_map { |m| m["ack"] }

  def send_update(update, id:)
    perform :receive, "update" => Updates.frame(update), "id" => id
  end

  test "paints are recorded, acked, and read back in order" do
    subscribe token: Demos.room_token("pixels", "room1")

    assert_predicate subscription, :confirmed?
    assert_equal 1, Rooms.current.peers(KEY)

    Updates::PIXEL_PAINTS.each_with_index { |update, i| send_update(update, id: i + 1) }

    assert_equal [1, 2, 3], acks
    assert_equal 3, Y::DocumentUpdate.count
    assert_equal({ "0,0" => 3, "1,0" => 2 }, PixelCanvas.cells(Y::Document.load_state(KEY)))
  end

  test "the log is never compacted: sixty-five updates stay sixty-five rows" do
    subscribe token: Demos.room_token("pixels", "room1")
    65.times { |i| send_update(Updates::PIXEL_PAINTS[0], id: i) }

    assert_equal 65, acks.size
    assert_equal 65, Y::DocumentUpdate.count
    assert_nil Y::Document.locate(KEY).state
  end

  test "a raw document key is rejected, the same as DocumentChannel" do
    subscribe id: KEY

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end
end
