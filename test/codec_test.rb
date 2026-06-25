# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"

# The stateless protocol codec, exposed as YrbLite module functions: classify a
# frame (message_kind), extract its document delta (update_from_message), and
# wrap a raw update into a relayable frame (wrap_update). No object or state is
# involved, the server never holds presence or document state to route a frame.
class CodecTest < Minitest::Test
  def test_wrap_update_round_trips_through_the_codec
    frame = YrbLite.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)

    assert_kind_of String, frame
    assert_equal 2, YrbLite.message_kind(frame), "a wrapped update classifies as a document update"
    refute_nil YrbLite.update_from_message(frame), "the document delta is extractable"
  end

  def test_message_kind_classifies_awareness_and_drops_garbage
    assert_equal 3, YrbLite.message_kind(YjsFixtures::Presence::FRAME), "awareness frame"
    assert_equal 0, YrbLite.message_kind(""), "empty -> drop"
    assert_equal 0, YrbLite.message_kind("\xff\xff\xff".b), "garbage -> drop"
  end

  def test_update_from_message_is_nil_for_non_document_frames
    assert_nil YrbLite.update_from_message(YjsFixtures::Presence::FRAME), "awareness carries no document delta"
    assert_nil YrbLite.update_from_message(YrbLite::Doc.new.sync_step1), "sync step1 carries no document delta"
  end

  def test_constants
    assert_equal 0, YrbLite::MSG_SYNC
    assert_equal 1, YrbLite::MSG_AWARENESS
    assert_equal 0, YrbLite::MSG_SYNC_STEP1
    assert_equal 1, YrbLite::MSG_SYNC_STEP2
    assert_equal 2, YrbLite::MSG_SYNC_UPDATE
  end
end
