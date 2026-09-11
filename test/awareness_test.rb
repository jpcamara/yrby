# frozen_string_literal: true

require "test_helper"
require "json"

# Y::Awareness lets a Ruby process publish presence: it produces the y-protocol
# awareness frames a browser applies as another participant. The bytes are the
# same wire format Yjs uses, so no client change is needed.
class AwarenessTest < Minitest::Test
  def test_a_client_id_is_stable_and_can_be_pinned
    a = Y::Awareness.new

    assert_kind_of Integer, a.client_id
    assert_equal a.client_id, a.client_id
    assert_equal 42, Y::Awareness.new(42).client_id
  end

  def test_set_local_state_returns_an_awareness_frame_carrying_the_state
    frame = Y::Awareness.new.set_local_state(JSON.generate(name: "Agent", color: "#7c3aed"))

    assert_equal Encoding::ASCII_8BIT, frame.encoding
    assert_equal 1, frame.bytes.first, "y-protocols message type 1 == awareness"
    assert_equal 3, Y.message_kind(frame), "yrby classifies it as an awareness frame to relay"
    assert_includes frame, "Agent"
    assert_includes frame, "7c3aed"
  end

  def test_clear_local_state_returns_a_removal_frame
    a = Y::Awareness.new
    a.set_local_state(JSON.generate(name: "Agent"))
    frame = a.clear_local_state

    assert_equal 1, frame.bytes.first
    assert_equal 3, Y.message_kind(frame)
    refute_includes frame, "Agent"
  end

  def test_a_frame_from_another_client_is_applied_and_readable
    ada = Y::Awareness.new(7)
    mirror = Y::Awareness.new(9)

    assert mirror.apply_update(ada.set_local_state(JSON.generate(name: "Ada", color: "#f00")))
    assert_equal({ "name" => "Ada", "color" => "#f00" }, mirror.states[7])

    mirror.apply_update(ada.clear_local_state)

    assert_nil mirror.states[7]
  end

  def test_a_document_update_is_not_a_presence_frame
    frame = Y.wrap_update(Y::Doc.new.encode_state_as_update)

    refute Y::Awareness.new.apply_update(frame)
  end

  def test_invalid_json_is_rejected
    assert_raises(Y::Error) { Y::Awareness.new.set_local_state("not json") }
  end
end
