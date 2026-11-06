require "test_helper"

# RoomChannel, yrby-rails' Y::DocumentChannel opened to a room's shape demo
# documents, and throttle layers 3-6 of config/limits.rb, tested through it.
class RoomChannelTest < ActionCable::Channel::TestCase
  tests RoomChannel

  setup do
    stub_connection(connection_id: "c1")
    @room = Room.create!(slug: "room1")
    @closes = []
    # ConnectionStub has no close; the flooding path calls it.
    closes = @closes
    connection.define_singleton_method(:close) { |**opts| closes << opts }
  end

  def document = @room.collaborative_document(:tiptap)

  def subscribe_to_room = subscribe(grant: document.grant, name: "tiptap")

  def acks = transmissions.filter_map { |m| m["ack"] }

  def notices = transmissions.filter_map { |m| m["notice"] }

  def send_update(update, id:)
    perform :receive, "update" => Updates.frame(update), "id" => id
  end

  test "a room's grant subscribes and gets the opening handshake" do
    subscribe_to_room

    assert_predicate subscription, :confirmed?
    assert_equal 1, Rooms.current.peers(@room, "tiptap")
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
  end

  test "a missing grant is rejected" do
    subscribe name: "tiptap"

    assert_predicate subscription, :rejected?
  end

  test "a tampered grant is rejected" do
    subscribe grant: "#{document.grant}x", name: "tiptap"

    assert_predicate subscription, :rejected?
    assert_equal 0, Seat.count
  end

  test "a grant for one demo doesn't open another" do
    subscribe grant: document.grant, name: "kanban"

    assert_predicate subscription, :rejected?
  end

  test "the Lexxy field doesn't open here" do
    subscribe grant: @room.collaborative_document(:body).grant, name: "body"

    assert_predicate subscription, :rejected?
  end

  test "the example document's grant doesn't open a room channel" do
    example = ExampleDocument.create!
    subscribe grant: example.collaborative_document(:body).grant, name: "body"

    assert_predicate subscription, :rejected?
  end

  test "a deleted room's grant is rejected" do
    grant = document.grant
    @room.destroy!

    subscribe grant: grant, name: "tiptap"

    assert_predicate subscription, :rejected?
  end

  test "unsubscribing gives the seat back" do
    subscribe_to_room

    assert_equal 1, Rooms.current.peers(@room, "tiptap")

    unsubscribe

    assert_equal 0, Rooms.current.peers(@room, "tiptap")
  end

  test "a full room refuses the subscription" do
    Rooms.current = Rooms.new(max_peers: 1)
    Rooms.current.join(@room, "tiptap", "someone-else")

    subscribe_to_room

    assert_predicate subscription, :rejected?
  end

  test "a connection over its subscription cap is refused" do
    Rooms.current = Rooms.new(max_subscriptions: 1)
    Rooms.current.join(@room, "kanban", "c1")

    subscribe_to_room

    assert_predicate subscription, :rejected?
    assert_equal 0, Rooms.current.peers(@room, "tiptap"), "no seat taken"
    assert_equal 0, Y::Document.count, "no document created"
  end

  test "an update is recorded to the room's document and acked" do
    subscribe_to_room
    send_update(Updates::HELLO, id: 7)

    assert_equal [7], acks
    doc = Y::Doc.new
    doc.apply_update(document.load_state)

    assert_equal "hello world", doc.read_text("content")
    assert Y::Document.exists?(record: @room, name: "tiptap")
  end

  test "a frame over the size cap is dropped without an ack" do
    subscribe_to_room
    oversized = Base64.strict_encode64("x" * (Limits::MAX_FRAME_BYTES + 1))

    perform :receive, "update" => oversized, "id" => 9

    assert_empty acks
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "an update inside the size cap is accepted" do
    subscribe_to_room

    assert_operator Updates.frame(Updates::HELLO).bytesize, :<, RoomChannel::MAX_ENCODED_BYTES
    send_update(Updates::HELLO, id: 1)

    assert_equal [1], acks
  end

  test "frames past the token bucket are dropped" do
    subscribe_to_room
    # Send three times the burst as fast as the test can. The bucket refills
    # while this runs, so the exact number that gets through depends on the
    # clock. The whole burst gets through and some of the rest doesn't.
    total = Limits::FRAME_BURST * 3
    total.times { |i| send_update(Updates::HELLO, id: i) }

    assert_operator acks.length, :>=, Limits::FRAME_BURST, "the whole burst should get through"
    assert_operator acks.length, :<, total, "some frames past the burst should be dropped"
  end

  test "a client that keeps flooding has its connection closed" do
    subscribe_to_room
    # The burst goes through first, and then frames are dropped. One drop short
    # of the threshold, the connection is still open. The bucket refills as the
    # test runs, so the drop count can only be lower than expected here.
    short = Limits::FRAME_BURST + Limits::FRAME_DROPS_BEFORE_CLOSE - 1
    short.times { |i| send_update(Updates::HELLO, id: i) }

    assert_empty @closes, "not yet at the drop threshold"

    # Because of the refill, which frame reaches the threshold depends on the
    # clock, so keep sending until the connection closes.
    (short...(short * 4)).each do |i|
      break if @closes.any?

      send_update(Updates::HELLO, id: i)
    end

    assert_equal({ reason: "message rate limit", reconnect: false }, @closes.first)
  end

  test "frames refresh the connection's seats once per interval" do
    subscribe_to_room
    Seat.update_all(seen_at: 1.hour.ago)

    send_update(Updates::HELLO, id: 1)

    assert_operator Seat.sole.seen_at, :>, 1.minute.ago

    Seat.update_all(seen_at: 1.hour.ago)
    send_update(Updates::HELLO, id: 2)

    assert_operator Seat.sole.seen_at, :<, 1.minute.ago, "the next refresh waits for SEAT_TOUCH_INTERVAL"
  end

  test "an update carrying a data: URL is refused, not stored, and reported once" do
    subscribe_to_room

    assert_no_difference "Y::Document.count" do
      send_update(Updates.text("data:image/png;base64,iVBORw0KGgo="), id: 1)
      send_update(Updates.text("DATA:text/html,<b>x</b>"), id: 2)
    end

    assert_empty acks, "a refused update must not be acked"
    assert_equal ["file_refused"], notices
  end

  test "an update carrying a blob: URL is refused" do
    subscribe_to_room
    send_update(Updates.text("blob:https://example.com/0f6c"), id: 1)

    assert_empty acks
    assert_equal ["file_refused"], notices
  end

  test "text that only mentions data: or blob: is accepted" do
    subscribe_to_room
    send_update(Updates.text("metadata: the blob: column holds data: rows"), id: 1)

    assert_equal [1], acks
    assert_empty notices
  end

  test "a room at its byte cap stops accepting writes and says so" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe_to_room
    send_update(Updates::HELLO, id: 1)

    assert_equal [1], acks
    assert Rooms.current.document_full?(document.key)

    send_update(Updates::HELLO, id: 2)

    assert_equal [1], acks, "the second update must not be acked"
    assert_equal ["document_full"], notices
    assert_equal 1, Y::DocumentUpdate.count, "the refused update must not be recorded"
  end

  test "the full-room notice is sent once" do
    Rooms.current = Rooms.new(max_document_bytes: 1)
    subscribe_to_room
    3.times { |i| send_update(Updates::HELLO, id: i) }

    assert_equal 1, notices.length
  end

  test "presence still works in a room that stopped accepting writes" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe_to_room
    send_update(Updates::HELLO, id: 1)

    assert Rooms.current.document_full?(document.key)

    assert_broadcasts("yrby:#{document.key}", 1) do
      perform :receive, "update" => Updates.awareness_frame
    end
  end

  test "a frame that is not base64 is dropped without an ack" do
    subscribe_to_room

    perform :receive, "update" => "not base64 !!!", "id" => 3

    assert_empty acks
  end
end
