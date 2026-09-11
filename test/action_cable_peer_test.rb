# frozen_string_literal: true

require_relative "document_channel_test"
require "json"

# A Peer follows a document over the cable's pubsub: broadcast updates land in
# its doc and fire on_update; presence frames go to on_awareness; anything
# else is ignored. Delivery is asynchronous, so the tests wait on a queue.
class ActionCablePeerTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  def setup
    @events = Queue.new
    @peer = Y::ActionCable::Peer.new("peer-test")
    @peer.on_update { |update, doc, changed| @events << [:update, update, doc.read_xml("root"), changed] }
    @peer.on_awareness { |frame| @events << [:awareness, frame] }
    @peer.subscribe
  end

  def teardown
    @peer.unsubscribe
  end

  def test_a_broadcast_update_lands_in_the_doc_and_fires_on_update
    source = Y::Doc.new
    update = source.diff { |d| Y::Lexical.append_paragraph(d, "hello from a browser") }

    Y::ActionCable.broadcast("peer-test", update)

    kind, received, text, changed = @events.pop(timeout: 2)

    assert_equal :update, kind
    assert_equal update, received
    assert_equal "hello from a browser", text
    assert_equal [0], changed, "the first block was added"
    assert_equal "hello from a browser", @peer.doc.read_xml("root")
  end

  def test_an_update_the_doc_already_holds_does_not_fire
    update = @peer.doc.diff { |d| Y::Lexical.append_paragraph(d, "written through the peer") }

    Y::ActionCable.broadcast("peer-test", update) # the peer's own edit, echoed back

    assert_nil @events.pop(timeout: 0.5)
    assert_equal "written through the peer", @peer.doc.read_xml("root")
  end

  def test_a_presence_frame_goes_to_on_awareness_and_leaves_the_doc_alone
    frame = Y::Awareness.new.set_local_state(JSON.generate(name: "Agent"))

    Y::ActionCable.broadcast_awareness("peer-test", frame)

    kind, received = @events.pop(timeout: 2)

    assert_equal :awareness, kind
    assert_equal frame, received
    assert_nil @peer.doc.read_xml("root")
  end

  def test_garbage_on_the_stream_is_ignored
    ActionCable.server.pubsub.broadcast("yrby:peer-test", "not json at all")
    ActionCable.server.pubsub.broadcast("yrby:peer-test", JSON.generate("update" => "!!not base64"))
    ActionCable.server.pubsub.broadcast("yrby:peer-test",
                                        JSON.generate("update" => Base64.strict_encode64("\x63\x63\x63")))

    assert_nil @events.pop(timeout: 0.5)
  end

  def test_unsubscribe_stops_delivery
    @peer.unsubscribe
    update = Y::Doc.new.diff { |d| Y::Lexical.append_paragraph(d, "after unsubscribe") }

    Y::ActionCable.broadcast("peer-test", update)

    assert_nil @events.pop(timeout: 0.5)
    @peer.subscribe # so teardown's unsubscribe is balanced
  end

  def test_with_no_root_an_update_applies_without_block_tracking
    events = Queue.new
    peer = Y::ActionCable::Peer.new("peer-text", root: nil)
    peer.on_update { |_update, doc, changed| events << [doc.get_text("markdown").to_s, changed] }
    peer.subscribe
    source = Y::Doc.new
    update = source.diff { |d| d.get_text("markdown").insert(0, "# Title\n") }

    Y::ActionCable.broadcast("peer-text", update)

    text, changed = events.pop(timeout: 2)

    assert_equal "# Title\n", text
    assert_nil changed
  ensure
    peer&.unsubscribe
  end
end
