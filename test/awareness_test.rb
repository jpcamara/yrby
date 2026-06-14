# frozen_string_literal: true

require "test_helper"

class AwarenessTest < Minitest::Test
  def test_awareness_creation
    awareness = YrbLite::Awareness.new
    assert_instance_of YrbLite::Awareness, awareness
  end

  def test_awareness_with_client_id
    awareness = YrbLite::Awareness.new(12345)
    assert_equal 12345, awareness.client_id
  end

  def test_awareness_has_random_client_id
    awareness = YrbLite::Awareness.new
    assert_kind_of Integer, awareness.client_id
    assert awareness.client_id > 0
  end

  def test_awareness_has_guid
    awareness = YrbLite::Awareness.new
    guid = awareness.guid
    assert_kind_of String, guid
    refute_empty guid
  end

  def test_encode_state_vector
    awareness = YrbLite::Awareness.new
    sv = awareness.encode_state_vector
    assert_kind_of String, sv
  end

  def test_encode_state_as_update_without_state_vector
    awareness = YrbLite::Awareness.new
    update = awareness.encode_state_as_update
    assert_kind_of String, update
  end

  def test_encode_state_as_update_with_state_vector
    a1 = YrbLite::Awareness.new(1)
    a2 = YrbLite::Awareness.new(2)

    sv = a2.encode_state_vector
    update = a1.encode_state_as_update(sv)

    assert_kind_of String, update
  end

  def test_start_returns_sync_messages
    awareness = YrbLite::Awareness.new
    messages = awareness.start
    assert_kind_of String, messages
    refute_empty messages
  end

  def test_handle_returns_response
    a1 = YrbLite::Awareness.new(1)
    a2 = YrbLite::Awareness.new(2)

    # a1 sends initial sync messages
    initial = a1.start

    # a2 handles them and returns response
    response = a2.handle(initial)
    assert_kind_of String, response
  end

  def test_full_sync_exchange
    a1 = YrbLite::Awareness.new(1)
    a2 = YrbLite::Awareness.new(2)

    # a1 initiates sync
    msg1 = a1.start

    # a2 handles and responds
    response1 = a2.handle(msg1)

    # a1 handles response (should complete sync)
    a1.handle(response1)

    # a2 initiates its own sync
    msg2 = a2.start

    # a1 handles and responds
    response3 = a1.handle(msg2)

    # a2 handles response
    a2.handle(response3)

    # Both should now have same state vectors
    assert_equal a1.encode_state_vector, a2.encode_state_vector
  end

  def test_encode_update
    awareness = YrbLite::Awareness.new
    update_data = "\x01\x02\x03"
    encoded = awareness.encode_update(update_data)
    assert_kind_of String, encoded
    refute_empty encoded
  end

  def test_local_state
    awareness = YrbLite::Awareness.new

    # Initially nil
    assert_nil awareness.local_state

    # Set state
    awareness.set_local_state('{"user": "test"}')
    state = awareness.local_state
    assert_kind_of String, state
    assert_includes state, "user"

    # Clear state
    awareness.clear_local_state
    assert_nil awareness.local_state
  end

  def test_encode_awareness_update
    awareness = YrbLite::Awareness.new
    awareness.set_local_state('{"cursor": {"x": 10, "y": 20}}')

    update = awareness.encode_awareness_update
    assert_kind_of String, update
    refute_empty update
  end

  def test_constants
    assert_equal 0, YrbLite::MSG_SYNC
    assert_equal 1, YrbLite::MSG_AWARENESS
    assert_equal 2, YrbLite::MSG_AUTH
    assert_equal 3, YrbLite::MSG_QUERY_AWARENESS
    assert_equal 0, YrbLite::MSG_SYNC_STEP1
    assert_equal 1, YrbLite::MSG_SYNC_STEP2
    assert_equal 2, YrbLite::MSG_SYNC_UPDATE
  end
end
