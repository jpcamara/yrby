require "test_helper"

# LexxyChannel, lexxy-realtime's channel opened to any room's body: the
# room's grant, storage through the record, the server rendering the room's
# plain body column, and the site's throttles from RecordChannelGuard.
class LexxyChannelTest < ActionCable::Channel::TestCase
  tests LexxyChannel

  # A full Lexical document captured from a real Lexxy editor. lexxy-realtime's
  # own tests use the same fixture to check byte-for-byte output. Y::Lexxy
  # renders it, so these tests check rendering against real content.
  LEXXY_STATE = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))

  setup do
    stub_connection(connection_id: "c1")
    @room = Room.create!(slug: "e2e-room")
  end

  def document = @room.collaborative_document(:body)
  def subscribe_to_room = subscribe(grant: document.grant, name: "body", session_id: "s1")
  def acks = transmissions.filter_map { |m| m["ack"] }

  test "the room's grant subscribes, takes a seat, and gets the handshake" do
    subscribe_to_room

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
    assert_equal 1, Rooms.current.peers(@room, "body")
    assert_equal 0, Y::Document.count, "the document row waits for the first write"
  end

  test "the first write creates the room's document" do
    subscribe_to_room
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert Y::Document.exists?(key: document.key, record: @room, name: "body")
  end

  test "a garbage grant is rejected" do
    subscribe grant: "not-a-grant", name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Seat.count
  end

  test "a body grant sent for another field is rejected" do
    subscribe grant: document.grant, name: "tiptap"

    assert_predicate subscription, :rejected?
  end

  test "yrby-rails' grant for a shape demo doesn't open here" do
    subscribe grant: @room.collaborative_document(:tiptap).grant, name: "tiptap"

    assert_predicate subscription, :rejected?
  end

  test "an update is recorded through the room's document and acked" do
    subscribe_to_room

    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 7

    assert_equal [7], acks
    assert_equal 1, document.document_row.updates.count
  end

  test "an update carrying a data: URL is refused and never reaches the body" do
    subscribe_to_room

    perform :receive, "update" => Updates.frame(Updates.text("data:image/gif;base64,R0lGODlhAQABAA==")), "id" => 8

    assert_empty acks
    assert_equal(["file_refused"], transmissions.filter_map { |m| m["notice"] })
    assert_nil @room.reload.body
  end

  test "a Lexical update is rendered into the plain body column" do
    subscribe_to_room

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal [1], acks
    body = @room.reload.body

    assert_predicate body, :present?, "the body column should hold the server-rendered HTML"
    assert_includes body, "<h1>Heading One</h1>"
  end

  test "a non-Lexical update is stored but not rendered" do
    subscribe_to_room
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal [1], acks, "the update is still recorded"
    assert_nil @room.reload.body, "Y::Lexxy returns nil for a non-Lexical document, so body is unchanged"
  end

  test "the room byte cap applies to this channel" do
    # Set the cap to one update's size. The first update fills the room, and
    # the second would go over the cap, so it's refused.
    one_update = Y.update_from_message(Base64.strict_decode64(Updates.frame(LEXXY_STATE)))
    Rooms.current = Rooms.new(max_document_bytes: one_update.bytesize)
    subscribe_to_room

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 2

    assert_equal [1], acks, "the first write fills the room and the second is over the cap"
    assert(transmissions.any? { |m| m["notice"] == "document_full" })
  end

  test "presence still works in a full room" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe_to_room
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert Rooms.current.document_full?(document.key)

    # Awareness comes in through `send`, so the server relays it even after the
    # room stops accepting document writes.
    assert_broadcasts("yrby:#{document.key}", 1) do
      perform :receive, "update" => Updates.awareness_frame
    end
  end

  test "the peer cap applies" do
    Rooms.current = Rooms.new(max_peers: 1)
    Rooms.current.join(@room, "body", "someone-else")

    subscribe_to_room

    assert_predicate subscription, :rejected?
  end

  test "unsubscribing releases the seat" do
    subscribe_to_room

    assert_equal 1, Rooms.current.peers(@room, "body")

    unsubscribe

    assert_equal 0, Rooms.current.peers(@room, "body")
  end

  test "destroying the room destroys its documents and seats" do
    subscribe_to_room
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal 1, Y::Document.count

    @room.destroy!

    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count
    assert_equal 0, Seat.count
  end
end
