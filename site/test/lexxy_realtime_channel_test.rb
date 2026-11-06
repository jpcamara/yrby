require "test_helper"

# lexxy-realtime's own channel is reachable by name. This site never renders a
# grant for it, and the example-only authorize_document block it inherits from
# Y::DocumentChannel refuses every Room, so a client that skips LexxyChannel
# gets nothing.
class LexxyRealtimeChannelTest < ActionCable::Channel::TestCase
  tests LexxyRealtime::DocumentChannel

  setup { stub_connection(connection_id: "c1") }

  test "a real grant for a room is still refused" do
    room = Room.create!(slug: "room1")
    subscribe grant: room.collaborative_document(:body).grant, name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Seat.count
  end
end
