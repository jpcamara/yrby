require "test_helper"

# The lexxy-realtime channel: signed-GlobalID auth, record-based storage, and
# the server-side materialization into the note's plain body column.
class NoteChannelTest < ActionCable::Channel::TestCase
  tests NoteChannel

  # A full Lexical document captured from a real Lexxy editor (the fixture
  # lexxy-realtime's own tests pin byte-parity with). Y::Lexxy renders it, so
  # materialization can be asserted on real content here.
  LEXXY_STATE = File.binread(File.expand_path("fixtures/lexxy_full.bin", __dir__))

  setup do
    stub_connection(connection_id: "c1")
    @note = Note.create!(room: "e2e-room")
  end

  def subscribe_with_valid_sgid
    subscribe sgid: @note.body_sgid, field: "body"
  end

  def acks = transmissions.filter_map { |m| m["ack"] }

  test "a valid sgid subscribes and gets the opening handshake" do
    subscribe_with_valid_sgid

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
    # The join minted the record-bound document with the derived key.
    assert Y::Document.exists?(key: "note/#{@note.id}/body")
    assert_equal 1, Rooms.current.peers("note/#{@note.id}/body")
  end

  test "a garbage sgid is rejected" do
    subscribe sgid: "not-a-token", field: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  test "a token minted for another purpose is rejected" do
    subscribe sgid: @note.to_sgid(for: "something_else").to_s, field: "body"

    assert_predicate subscription, :rejected?
  end

  test "a body token cannot join another field" do
    # The purpose embeds the field, so presenting a body token with a
    # different field param fails the locate — the gem's scoping contract.
    subscribe sgid: @note.body_sgid, field: "room"

    assert_predicate subscription, :rejected?
  end

  test "a non-collaborative field is rejected even with a matching token" do
    subscribe sgid: @note.to_sgid(for: Note.sgid_purpose(:room)).to_s, field: "room"

    assert_predicate subscription, :rejected?
  end

  test "an update is recorded through the record's document and acked" do
    subscribe_with_valid_sgid

    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 7

    assert_equal [7], acks
    assert_equal 1, @note.reload.collaborative_document(:body).updates.count
  end

  test "a lexical update materializes into the plain body column" do
    subscribe_with_valid_sgid

    assert_nil @note.body

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal [1], acks
    body = @note.reload.body

    assert_predicate body, :present?, "the body column should hold the server-rendered HTML"
    assert_includes body, "<h1>Heading One</h1>"
  end

  test "a non-lexical update is stored but does not materialize" do
    subscribe_with_valid_sgid
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 1

    assert_equal [1], acks, "recording succeeds regardless"
    assert_nil @note.reload.body, "Y::Lexxy returns nil for a foreign shape; the column stays put"
  end

  test "the throttle layers guard this channel too" do
    Rooms.current = Rooms.new(max_document_bytes: 1)
    subscribe_with_valid_sgid

    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 2

    assert_equal [1], acks, "the second update hits the byte cap"
    assert(transmissions.any? { |m| m["notice"] == "document_full" })
  end

  test "the peer cap applies to note rooms" do
    Rooms.current = Rooms.new(max_peers: 1)
    Rooms.current.join("note/#{@note.id}/body")

    subscribe_with_valid_sgid

    assert_predicate subscription, :rejected?
  end

  test "unsubscribing releases the seat" do
    subscribe_with_valid_sgid

    assert_equal 1, Rooms.current.peers("note/#{@note.id}/body")

    unsubscribe

    assert_equal 0, Rooms.current.peers("note/#{@note.id}/body")
  end

  test "destroying the note destroys its document and updates" do
    subscribe_with_valid_sgid
    perform :receive, "update" => Updates.frame(LEXXY_STATE), "id" => 1

    assert_equal 1, Y::Document.count

    @note.destroy!

    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count
  end
end
