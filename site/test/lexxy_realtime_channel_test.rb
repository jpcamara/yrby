require "test_helper"

# lexxy-realtime's own channel is reachable by name. This site never renders a
# grant for it, and the example-only authorize_document block it inherits from
# Y::DocumentChannel refuses every Note, so a client that skips NoteChannel
# gets nothing.
class LexxyRealtimeChannelTest < ActionCable::Channel::TestCase
  tests LexxyRealtime::DocumentChannel

  setup { stub_connection(connection_id: "c1") }

  test "a room token is not a grant here" do
    subscribe grant: Note.room_token("room1", :body), name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count
  end

  test "a real grant for a Note is still refused" do
    note = Note.create!(room: "room1")
    subscribe grant: note.collaborative_rich_text_grant(:body), name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Rooms.current.peers(Y::Document.key_for(note, :body))
  end
end
