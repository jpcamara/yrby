require "test_helper"

class ExampleDocumentChannelTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  setup do
    stub_connection(connection_id: "example-c1")
    @document = ExampleDocument.find_or_create_by!(id: 1)
  end

  def join_example
    subscribe grant: @document.collaborative_sgid(:body), name: "body", session_id: "example-session"
  end

  test "the shipped channel syncs the example and releases its room seat" do
    join_example

    assert_predicate subscription, :confirmed?
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 3

    assert(transmissions.any? { |message| message["ack"] == 3 })
    assert_equal "hello world", @document.collaborative_document(:body).doc.read_text("content")
    key = @document.collaborative_document(:body).key

    assert_equal 1, Rooms.current.peers(key)
    unsubscribe

    assert_equal 0, Rooms.current.peers(key)
  end

  test "invalid and wrong-attribute grants cannot allocate storage" do
    assert_no_difference "Y::Document.count" do
      subscribe grant: @document.collaborative_sgid(:body), name: "secret"
    end

    assert_predicate subscription, :rejected?
  end

  test "even a valid grant for another record cannot bypass the public example policy" do
    other = ExampleDocument.create!
    subscribe grant: other.collaborative_sgid(:body), name: "body"

    assert_predicate subscription, :rejected?
  end

  test "the shipped channel also enforces the site's room cap" do
    Rooms.current = Rooms.new(max_peers: 0)
    assert_no_difference "Y::Document.count" do
      join_example
    end

    assert_predicate subscription, :rejected?
  end

  test "an over-limit write is not stored or acknowledged" do
    Rooms.current = Rooms.new(max_document_bytes: 1)
    join_example
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 4

    assert_nil @document.collaborative_document(:body).load_state
    assert(transmissions.none? { |message| message["ack"] == 4 })
    assert(transmissions.any? { |message| message["notice"] == "document_full" })
  end

  test "receive rechecks the policy before calling the recorder" do
    join_example
    subscription.params[:name] = "secret"
    perform :receive, "update" => Updates.frame(Updates::HELLO), "id" => 5

    assert_predicate subscription, :rejected?
    assert_nil @document.collaborative_document(:body).load_state
  end
end
