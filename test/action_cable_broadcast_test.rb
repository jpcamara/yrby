# frozen_string_literal: true

require_relative "document_channel_test"
require "json"

# Module-level broadcasts from outside a channel. A client reads each frame's
# first byte as its message type, so a document update must go out framed as
# a sync message, and a presence frame (already complete) must go out as is.
class ActionCableBroadcastTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  # A y-protocol awareness message as a browser sends it: type byte 1, one
  # client (id 42), clock 1, state {"name":"Agent"}. Captured from yrs.
  AWARENESS_FRAME = "\x01\x14\x01\x2a\x01\x10\x7b\x22\x6e\x61\x6d\x65\x22\x3a\x22\x41\x67\x65\x6e\x74\x22\x7d".b.freeze

  def test_a_document_update_is_framed_as_a_sync_message
    doc = Y::Doc.new
    doc.get_text("content").push("hi")
    update = doc.encode_state_as_update

    Y::ActionCable.broadcast("k", update)

    frame = Base64.strict_decode64(JSON.parse(broadcasts("yrby:k").last)["update"])

    assert_equal 0, frame.bytes.first, "y-protocol message type 0 == sync"
    assert_equal Y::ActionCable::Sync::MSG_KIND_UPDATE, Y.message_kind(frame)
    assert_equal update, Y.update_from_message(frame)
  end

  def test_a_presence_frame_is_relayed_unchanged
    Y::ActionCable.broadcast_awareness("k", AWARENESS_FRAME)

    sent = Base64.strict_decode64(JSON.parse(broadcasts("yrby:k").last)["update"])

    assert_equal AWARENESS_FRAME, sent
    assert_equal Y::ActionCable::Sync::MSG_KIND_AWARENESS, Y.message_kind(sent)
  end
end
