require "test_helper"

# Layers 3-6 of the throttle stack, driven through the real channel.
class DocumentChannelTest < ActionCable::Channel::TestCase
  tests DocumentChannel

  KEY = "tiptap/room1".freeze

  setup do
    stub_connection(connection_id: "c1")
    @closes = []
    # ConnectionStub has no close; the flooding path calls it.
    closes = @closes
    connection.define_singleton_method(:close) { |**opts| closes << opts }
  end

  def acks = transmissions.filter_map { |m| m["ack"] }

  def notices = transmissions.filter_map { |m| m["notice"] }

  # Signs an arbitrary key, bypassing room_token's slug/room shape, so tests
  # can prove the channel re-validates what a token carries.
  def token_for(key) = Demos.verifier.generate(key)

  def send_update(update, id:)
    perform :receive, "update" => Updates.frame(update), "id" => id
  end

  test "a signed token subscribes and gets the opening handshake" do
    subscribe token: Demos.room_token("tiptap", "room1")

    assert_predicate subscription, :confirmed?
    assert_equal 1, Rooms.current.peers(KEY)
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
  end

  test "a raw document key is rejected: clients cannot name documents" do
    subscribe id: KEY

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  test "a missing token is rejected" do
    subscribe

    assert_predicate subscription, :rejected?
  end

  test "a tampered token is rejected" do
    subscribe token: "#{Demos.room_token("tiptap", "room1")}x"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  test "a signed token for a key outside the demo namespace is rejected" do
    subscribe token: token_for("../../etc/passwd")

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  test "a signed token for an unknown demo slug is rejected" do
    subscribe token: token_for("wiki/room1")

    assert_predicate subscription, :rejected?
  end

  test "a signed token for an over-long room id is rejected" do
    subscribe token: token_for("tiptap/#{"a" * 33}")

    assert_predicate subscription, :rejected?
  end

  test "unsubscribing gives the seat back" do
    subscribe token: Demos.room_token("tiptap", "room1")

    assert_equal 1, Rooms.current.peers(KEY)

    unsubscribe

    assert_equal 0, Rooms.current.peers(KEY)
  end

  test "a full room refuses the subscription" do
    Rooms.current = Rooms.new(max_peers: 1)
    Rooms.current.join(KEY)

    subscribe token: Demos.room_token("tiptap", "room1")

    assert_predicate subscription, :rejected?
  end

  test "a connection over its subscription cap is refused" do
    # Saturate this connection's guard (connection_id "c1" from setup), then a
    # further subscribe is refused before it can take a seat or mint a document.
    ConnectionGuard.current = ConnectionGuard.new(max_subscriptions: 1)
    ConnectionGuard.current.admit_subscription("c1", "tiptap/elsewhere")

    subscribe token: Demos.room_token("tiptap", "room1")

    assert_predicate subscription, :rejected?
    assert_equal 0, Rooms.current.peers(KEY), "no seat taken"
    assert_equal 0, Y::Document.count, "no document minted"
  end

  test "the room cap refuses a subscription that would mint a new document" do
    Rooms.current = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO)

    subscribe token: Demos.room_token("tiptap", "room1")

    assert_predicate subscription, :rejected?
  end

  test "an update is recorded to the database and acked" do
    subscribe token: Demos.room_token("tiptap", "room1")
    send_update(Updates::HELLO, id: 7)

    assert_equal [7], acks
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state(KEY))

    assert_equal "hello world", doc.read_text("content")
    assert_equal 1, Y::DocumentUpdate.count
  end

  test "a frame over the size cap is dropped without an ack" do
    subscribe token: Demos.room_token("tiptap", "room1")
    oversized = Base64.strict_encode64("x" * (Limits::MAX_FRAME_BYTES + 1))

    perform :receive, "update" => oversized, "id" => 9

    assert_empty acks
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "an update inside the size cap is accepted" do
    subscribe token: Demos.room_token("tiptap", "room1")

    assert_operator Updates.frame(Updates::HELLO).bytesize, :<, DocumentChannel::MAX_ENCODED_BYTES
    send_update(Updates::HELLO, id: 1)

    assert_equal [1], acks
  end

  test "frames past the token bucket are dropped" do
    subscribe token: Demos.room_token("tiptap", "room1")
    # Three times the burst, sent as fast as the test can. The bucket refills
    # while that runs, so the exact number that gets through depends on the wall
    # clock; what is fixed is that the burst is honoured and the rest is not.
    total = Limits::FRAME_BURST * 3
    total.times { |i| send_update(Updates::HELLO, id: i) }

    assert_operator acks.length, :>=, Limits::FRAME_BURST, "the burst should have been honoured"
    assert_operator acks.length, :<, total, "everything past the burst should not have got through"
  end

  test "a client that keeps flooding has its connection closed" do
    subscribe token: Demos.room_token("tiptap", "room1")
    # The burst is spent first, then every frame is a drop. One short of the
    # threshold the connection is still up. (The bucket refills as the test
    # runs, so the count can only lag, never lead.)
    short = Limits::FRAME_BURST + Limits::FRAME_DROPS_BEFORE_CLOSE - 1
    short.times { |i| send_update(Updates::HELLO, id: i) }

    assert_empty @closes, "not yet at the drop threshold"

    # Refill means the exact frame that trips the threshold depends on the wall
    # clock, so keep sending until it does.
    (short...(short * 4)).each do |i|
      break if @closes.any?

      send_update(Updates::HELLO, id: i)
    end

    assert_equal({ reason: "message rate limit", reconnect: false }, @closes.first)
  end

  test "a room at its byte cap stops accepting writes and says so" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe token: Demos.room_token("tiptap", "room1")
    send_update(Updates::HELLO, id: 1)

    assert_equal [1], acks
    assert Rooms.current.document_full?(KEY)

    send_update(Updates::HELLO, id: 2)

    assert_equal [1], acks, "the second update must not be acked"
    assert_equal ["document_full"], notices
    assert_equal 1, Y::DocumentUpdate.count, "the refused update must not be recorded"
  end

  test "the full-room notice is sent once, not on every dropped frame" do
    Rooms.current = Rooms.new(max_document_bytes: 1)
    subscribe token: Demos.room_token("tiptap", "room1")
    3.times { |i| send_update(Updates::HELLO, id: i) }

    assert_equal 1, notices.length
  end

  test "presence still flows in a room that has stopped accepting writes" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe token: Demos.room_token("tiptap", "room1")
    send_update(Updates::HELLO, id: 1)

    assert Rooms.current.document_full?(KEY)

    assert_broadcasts("yrby:#{KEY}", 1) do
      perform :receive, "update" => Updates.awareness_frame
    end
  end

  test "a frame that is not base64 is dropped without an ack" do
    subscribe token: Demos.room_token("tiptap", "room1")

    perform :receive, "update" => "not base64 !!!", "id" => 3

    assert_empty acks
  end
end
