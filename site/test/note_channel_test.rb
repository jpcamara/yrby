require "test_helper"

# NoteChannel, lexxy-realtime's channel with a room token as the grant: room
# tokens scoped to a field, the Note created on subscribe (not on a page GET),
# storage through the record, the server rendering the note's plain body
# column, and the site's throttles from RecordChannelGuard.
class NoteChannelTest < ActionCable::Channel::TestCase
  tests NoteChannel

  # A full Lexical document captured from a real Lexxy editor. lexxy-realtime's
  # own tests use the same fixture to check byte-for-byte output. Y::Lexxy
  # renders it, so these tests check rendering against real content.
  LEXXY_STATE = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))
  ROOM = "e2e-room".freeze

  setup { stub_connection(connection_id: "c1") }

  def token = Note.room_token(ROOM, :body)
  def subscribe_with_valid_token = subscribe grant: token, name: "body", session_id: "s1"
  def document_key = "note/#{Note.find_by!(room: ROOM).id}/body"
  def acks = transmissions.filter_map { |m| m["ack"] }

  test "a valid room token subscribes, creates the note, and gets the handshake" do
    assert_equal 0, Note.count, "no note exists until a client subscribes"

    subscribe_with_valid_token

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
    note = Note.find_by(room: ROOM)

    assert_not_nil note, "the note is created on subscribe"
    # The seat is on the record's document key. The document row itself waits
    # for the first write.
    assert_equal 1, Rooms.current.peers("note/#{note.id}/body")
    assert_equal 0, Y::Document.count
  end

  test "the first write creates the record's document" do
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    note = Note.find_by!(room: ROOM)

    assert Y::Document.exists?(key: "note/#{note.id}/body", record: note, name: "body")
  end

  test "a garbage token is rejected and creates nothing" do
    subscribe grant: "not-a-token", name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count
    assert_equal 0, Y::Document.count
  end

  test "a token made for another field is rejected" do
    # The verifier is keyed by a purpose that includes the field, so a token
    # for one field doesn't verify for another.
    subscribe grant: Note.room_token(ROOM, :title), name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count
  end

  test "a body token sent for another field is rejected" do
    subscribe grant: token, name: "title"

    assert_predicate subscription, :rejected?
  end

  test "a subscribe at the room cap creates no note" do
    Rooms.current = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO) # fills the one-room budget

    subscribe_with_valid_token

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count, "a subscribe past the cap must not create a note"
  end

  test "subscribing again reuses the existing note" do
    subscribe_with_valid_token
    note = Note.find_by!(room: ROOM)
    unsubscribe

    subscribe_with_valid_token

    assert_equal 1, Note.count
    assert_equal note.id, Note.find_by!(room: ROOM).id
  end

  test "an update is recorded through the record's document and acked" do
    subscribe_with_valid_token

    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 7

    assert_equal [7], acks
    assert_equal 1, Note.find_by!(room: ROOM).collaborative_document(:body).document_row.updates.count
  end

  test "a Lexical update is rendered into the plain body column" do
    subscribe_with_valid_token

    assert_nil Note.find_by!(room: ROOM).body

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal [1], acks
    body = Note.find_by!(room: ROOM).body

    assert_predicate body, :present?, "the body column should hold the server-rendered HTML"
    assert_includes body, "<h1>Heading One</h1>"
  end

  test "a non-Lexical update is stored but not rendered" do
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal [1], acks, "the update is still recorded"
    assert_nil Note.find_by!(room: ROOM).body, "Y::Lexxy returns nil for a non-Lexical document, so body is unchanged"
  end

  test "the room byte cap applies to this channel" do
    # Set the cap to one update's size. The first update fills the room, and
    # the second would go over the cap, so it's refused.
    one_update = Y.update_from_message(Base64.strict_decode64(Updates.frame(LEXXY_STATE)))
    Rooms.current = Rooms.new(max_document_bytes: one_update.bytesize)
    subscribe_with_valid_token

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 2

    assert_equal [1], acks, "the first write fills the room and the second is over the cap"
    assert(transmissions.any? { |m| m["notice"] == "document_full" })
  end

  test "presence still works in a full room" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert Rooms.current.document_full?(document_key)

    # Awareness comes in through `send`, so the server relays it even after the
    # room stops accepting document writes.
    assert_broadcasts("yrby:#{document_key}", 1) do
      perform :receive, "update" => Updates.awareness_frame
    end
  end

  test "the peer cap applies to note rooms" do
    # Create the note first so its key exists, then fill its one peer seat.
    note = Note.create!(room: ROOM)
    Rooms.current = Rooms.new(max_peers: 1)
    Rooms.current.join("note/#{note.id}/body")

    subscribe_with_valid_token

    assert_predicate subscription, :rejected?
  end

  test "unsubscribing releases the seat" do
    subscribe_with_valid_token
    key = document_key

    assert_equal 1, Rooms.current.peers(key)

    unsubscribe

    assert_equal 0, Rooms.current.peers(key)
  end

  test "destroying the note destroys its document and updates" do
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal 1, Y::Document.count

    Note.find_by!(room: ROOM).destroy!

    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count
  end

  test "a signed GlobalID is not a room token" do
    note = Note.create!(room: ROOM)
    subscribe grant: note.to_sgid(for: LexxyRealtime.grant_purpose(:body)).to_s, name: "body"

    assert_predicate subscription, :rejected?
  end
end
