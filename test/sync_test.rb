# frozen_string_literal: true

require "test_helper"
require "yrb_lite/sync"

class SyncTest < Minitest::Test
  class SyncHelper
    include YrbLite::Sync
  end

  def setup
    @helper = SyncHelper.new
    YrbLite::Sync.reset!
  end

  def test_doc_for_creates_new_doc
    doc1 = @helper.doc_for("test-room")
    doc2 = @helper.doc_for("test-room")

    assert_same doc1, doc2, "Should return same doc for same key"
  end

  def test_doc_for_different_keys
    doc1 = @helper.doc_for("room-1")
    doc2 = @helper.doc_for("room-2")

    refute_same doc1, doc2, "Should return different docs for different keys"
  end

  def test_docs_are_functional
    doc = @helper.doc_for("test-room")

    assert_kind_of YrbLite::Doc, doc
    assert_equal "\x00".b, doc.encode_state_vector
  end

  def test_reset_clears_docs
    @helper.doc_for("room-1")
    @helper.doc_for("room-2")

    refute_empty YrbLite::Sync.docs

    YrbLite::Sync.reset!

    assert_empty YrbLite::Sync.docs
  end

  def test_sync_step1_returns_encoded_message
    doc = @helper.doc_for("test-room")
    msg = doc.sync_step1

    # SyncStep1 message format: [0 (MSG_SYNC)][0 (STEP1)][length][state_vector]
    assert msg.is_a?(String)
    assert msg.encoding == Encoding::ASCII_8BIT
    assert msg.bytesize >= 3 # At minimum: msg_type + sync_type + length
  end

  def test_handle_sync_message_returns_tuple
    doc = @helper.doc_for("test-room")

    # Create a SyncStep1 message from another doc
    other_doc = YrbLite::Doc.new
    sync_step1 = other_doc.sync_step1

    result = doc.handle_sync_message(sync_step1)

    # Should return [msg_type, sync_type, response]
    assert result.is_a?(Array)
    assert_equal 3, result.length
    assert_equal 0, result[0] # MSG_SYNC
    assert_equal 0, result[1] # Responding to STEP1
    assert result[2].is_a?(String) # Response bytes (SyncStep2)
  end
end
