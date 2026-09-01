require "test_helper"

# The lexxy-realtime channel: signed, field-scoped room-token auth, the Note
# created lazily on subscribe (never on a page GET), record-based storage, and
# the server-side materialization into the note's plain body column.
class NoteChannelTest < ActionCable::Channel::TestCase
  tests NoteChannel

  # A full Lexical document captured from a real Lexxy editor (the fixture
  # lexxy-realtime's own tests pin byte-parity with). Y::Lexxy renders it, so
  # materialization can be asserted on real content here.
  LEXXY_STATE = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))
  ROOM = "e2e-room".freeze

  setup { stub_connection(connection_id: "c1") }

  def token = Note.room_token(ROOM, :body)
  def subscribe_with_valid_token = subscribe token: token, field: "body"
  def document_key = "note/#{Note.find_by!(room: ROOM).id}/body"
  def acks = transmissions.filter_map { |m| m["ack"] }

  test "a valid room token subscribes, creates the note, and gets the handshake" do
    assert_equal 0, Note.count, "no note exists until a client subscribes"

    subscribe_with_valid_token

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
    note = Note.find_by(room: ROOM)

    assert_not_nil note, "the note is minted on subscribe"
    # The join minted the record-bound document with the derived key.
    assert Y::Document.exists?(key: "note/#{note.id}/body")
    assert_equal 1, Rooms.current.peers("note/#{note.id}/body")
  end

  test "a garbage token is rejected and creates nothing" do
    subscribe token: "not-a-token", field: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count
    assert_equal 0, Y::Document.count
  end

  test "a token minted for another field is rejected" do
    # The verifier is keyed by the field-scoped purpose, so a body token does
    # not verify under a different field — the gem's field scoping.
    subscribe token: Note.room_token(ROOM, :title), field: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count
  end

  test "a body token presented for another field is rejected" do
    subscribe token: token, field: "title"

    assert_predicate subscription, :rejected?
  end

  test "a subscribe at the room cap creates no note" do
    Rooms.current = Rooms.new(max_rooms: 1)
    Y::Document.append("tiptap/taken", Updates::HELLO) # fills the one-room budget

    subscribe_with_valid_token

    assert_predicate subscription, :rejected?
    assert_equal 0, Note.count, "a subscribe past the cap must not mint a note"
  end

  test "a re-subscribe reuses the existing note rather than creating another" do
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
    assert_equal 1, Note.find_by!(room: ROOM).collaborative_document(:body).updates.count
  end

  test "a lexical update materializes into the plain body column" do
    subscribe_with_valid_token

    assert_nil Note.find_by!(room: ROOM).body

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal [1], acks
    body = Note.find_by!(room: ROOM).body

    assert_predicate body, :present?, "the body column should hold the server-rendered HTML"
    assert_includes body, "<h1>Heading One</h1>"
  end

  test "a non-lexical update is stored but does not materialize" do
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal [1], acks, "recording succeeds regardless"
    assert_nil Note.find_by!(room: ROOM).body, "Y::Lexxy returns nil for a foreign shape; the column stays put"
  end

  test "the throttle layers guard this channel too" do
    # Size the cap to exactly one update: the first fills the room, the second
    # crosses the cap and is refused (the prospective-reservation check).
    one_update = Y.update_from_message(Base64.strict_decode64(Updates.frame(LEXXY_STATE)))
    Rooms.current = Rooms.new(max_document_bytes: one_update.bytesize)
    subscribe_with_valid_token

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 2

    assert_equal [1], acks, "the first write fills the room; the second crosses the cap"
    assert(transmissions.any? { |m| m["notice"] == "document_full" })
  end

  test "presence still flows through the guarded path in a full room" do
    Rooms.current = Rooms.new(max_document_bytes: Updates::HELLO.bytesize)
    subscribe_with_valid_token
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert Rooms.current.document_full?(document_key)

    # Awareness is a `send`, not a whisper: it reaches the server and is relayed
    # even when the room has stopped accepting document writes.
    assert_broadcasts("yrby:#{document_key}", 1) do
      perform :receive, "update" => Updates.awareness_frame
    end
  end

  test "the peer cap applies to note rooms" do
    # Pre-create the note so the peer key exists, then fill its one peer seat.
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
end
