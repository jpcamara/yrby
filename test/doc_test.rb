# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "fixtures/yjs_fixtures"

class DocTest < Minitest::Test
  def test_doc_creation
    doc = Y::Doc.new

    assert_instance_of Y::Doc, doc
  end

  def test_doc_accepts_a_client_id_without_validation
    # A client_id can be supplied for CRDT identity, but it is not validated and
    # not readable back, keeping it JS-safe is the caller's job (an out-of-range
    # value is silently masked by yrs, not rejected). See protocol.rs.
    assert_instance_of Y::Doc, Y::Doc.new((2**53) - 1)
  end

  def test_encode_state_vector
    doc = Y::Doc.new
    sv = doc.encode_state_vector

    assert_kind_of String, sv
  end

  def test_encode_state_as_update_without_state_vector
    doc = Y::Doc.new
    update = doc.encode_state_as_update

    assert_kind_of String, update
  end

  def test_encode_state_as_update_with_state_vector
    d1 = Y::Doc.new(1)
    d2 = Y::Doc.new(2)

    sv = d2.encode_state_vector
    update = d1.encode_state_as_update(sv)

    assert_kind_of String, update
  end

  def test_sync_step1
    doc = Y::Doc.new
    step1 = doc.sync_step1

    assert_kind_of String, step1
    refute_empty step1
  end

  def test_handle_sync_message_step1
    d1 = Y::Doc.new(1)
    d2 = Y::Doc.new(2)

    step1 = d1.sync_step1

    result = d2.handle_sync_message(step1)

    assert_kind_of Array, result
    msg_type, sync_type, response = result

    assert_equal Y::MSG_SYNC, msg_type
    assert_equal Y::MSG_SYNC_STEP1, sync_type
    refute_empty response
  end

  def test_full_sync_exchange
    d1 = Y::Doc.new(1)
    d2 = Y::Doc.new(2)

    # d1 initiates sync (sends SyncStep1)
    step1 = d1.sync_step1

    # d2 handles SyncStep1, returns SyncStep2
    result = d2.handle_sync_message(step1)
    _msg_type, _sync_type, step2_response = result

    # d1 handles SyncStep2
    d1.handle_sync_message(step2_response)

    # Now d2 initiates sync
    step1_from_d2 = d2.sync_step1

    # d1 handles and responds
    result = d1.handle_sync_message(step1_from_d2)
    _msg_type, _sync_type, step2_from_d1 = result

    # d2 handles response
    d2.handle_sync_message(step2_from_d1)

    # Both should have same state vectors
    assert_equal d1.encode_state_vector, d2.encode_state_vector
  end

  # ============================================================================
  # Y.js Interop Tests (using pre-generated fixtures)
  # ============================================================================

  def test_apply_yjs_update
    doc = Y::Doc.new

    # Apply update generated from Y.js containing "hello world"
    doc.apply_update(YjsFixtures::TextHelloWorld::UPDATE)

    # State vector should match what Y.js produced
    assert_equal YjsFixtures::TextHelloWorld::STATE_VECTOR, doc.encode_state_vector
  end

  def test_apply_yjs_empty_doc
    doc = Y::Doc.new

    # Empty doc should have matching state vector
    assert_equal YjsFixtures::EmptyDoc::STATE_VECTOR, doc.encode_state_vector
  end

  def test_merge_two_yjs_docs
    doc = Y::Doc.new

    # Apply updates from two different Y.js docs
    doc.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    doc.apply_update(YjsFixtures::TwoDocsMerged::DOC2_UPDATE)

    # Verify both updates were applied by checking we can sync with a fresh doc
    doc2 = Y::Doc.new
    doc2.apply_update(doc.encode_state_as_update)

    # Both should have same state now
    assert_equal doc.encode_state_vector, doc2.encode_state_vector

    # State vector should have content from both clients (length > empty)
    assert_operator doc.encode_state_vector.bytesize, :>, YjsFixtures::EmptyDoc::STATE_VECTOR.bytesize
  end

  def test_sync_protocol_with_yjs_update
    doc = Y::Doc.new

    # Verify empty doc matches Y.js empty state vector
    assert_equal YjsFixtures::SyncProtocol::INITIAL_SV_DOC2, doc.encode_state_vector

    # Apply the diff update (what Y.js doc1 would send to sync)
    doc.apply_update(YjsFixtures::SyncProtocol::DIFF_UPDATE)

    # Should now have same state as the synced Y.js doc
    assert_equal YjsFixtures::SyncProtocol::FINAL_SV, doc.encode_state_vector
  end

  def test_encode_state_as_update_matches_yjs
    doc = Y::Doc.new

    # Apply Y.js update
    doc.apply_update(YjsFixtures::TextHelloWorld::UPDATE)

    # Get update diffed against empty state vector
    update = doc.encode_state_as_update(YjsFixtures::EmptyDoc::STATE_VECTOR)

    # Apply to a fresh doc
    doc2 = Y::Doc.new
    doc2.apply_update(update)

    # Both should have same state
    assert_equal doc.encode_state_vector, doc2.encode_state_vector
    assert_equal YjsFixtures::TextHelloWorld::STATE_VECTOR, doc2.encode_state_vector
  end

  def test_sync_protocol_messages_with_yjs_content
    # doc1 has Y.js content
    doc1 = Y::Doc.new
    doc1.apply_update(YjsFixtures::TextHelloWorld::UPDATE)

    # doc2 is empty
    doc2 = Y::Doc.new

    # doc2 initiates sync
    step1 = doc2.sync_step1

    # doc1 handles and responds with its content
    result = doc1.handle_sync_message(step1)
    _msg_type, _sync_type, step2_response = result

    # doc2 applies the response
    doc2.handle_sync_message(step2_response)

    # Both should now have the Y.js content
    assert_equal YjsFixtures::TextHelloWorld::STATE_VECTOR, doc2.encode_state_vector
    assert_equal doc1.encode_state_vector, doc2.encode_state_vector
  end

  # ---- read_text_delta: a Y.Text with its formatting ---------------------------

  def test_read_text_delta_of_plain_text_is_one_run
    doc = Y::Doc.new
    doc.get_text("t").insert(0, "plain")

    assert_equal [{ "insert" => "plain" }], JSON.parse(doc.read_text_delta("t"))
  end

  def test_read_text_delta_reads_what_a_yjs_client_wrote
    fixture = JSON.parse(File.read(File.expand_path("fixtures/trix.json", __dir__))).find { |f| f["name"] == "links" }
    doc = Y::Doc.new
    doc.apply_update(fixture["update"].unpack1("m"))
    delta = JSON.parse(doc.read_text_delta("trix"))

    assert_equal "link", delta[0]["insert"]
    assert_equal({ "href" => "https://example.com/a?b=1&c=2" }, delta[0]["attributes"])
    assert_equal({ "blockBreak" => true }, delta.last["attributes"])
    assert_equal doc.read_text("trix"), delta.map { |op| op["insert"] }.join
  end

  def test_read_text_delta_is_nil_for_a_missing_root_and_empty_for_an_empty_text
    doc = Y::Doc.new

    assert_nil doc.read_text_delta("nope")
    doc.get_text("t")

    assert_equal "[]", doc.read_text_delta("t")
  end
end
