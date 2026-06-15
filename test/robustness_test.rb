# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"

# The native extension decodes attacker-controlled bytes, and a Rust panic
# crossing the FFI boundary would take down the whole process. These tests feed
# it garbage and check that the worst case is a Ruby exception or a no-op,
# not a crash and not a corrupted document.
class RobustnessTest < Minitest::Test
  # A pile of junk byte strings to feed every decoder.
  def garbage_corpus
    rng = Random.new(0xBADC0DE)
    valid = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
    [
      "",                                  # empty
      "\x00".b,                            # single null
      "\xff\xff\xff\xff".b,                # high bits
      "\x00\x01\x02\x03\x04\x05".b,        # ascending
      "\x63\x63\x63".b,                    # unknown message type (99)
      "\x00\x01\xff\xff\xff\xff\x0f".b,    # sync/step2 with bogus huge varint length
      "\x01\xff\xff\xff\xff\x0f".b,        # awareness with bogus huge length
      valid[0...(valid.length / 2)],       # truncated valid update
      valid + "\xde\xad\xbe\xef".b,        # valid update with trailing junk
      rng.bytes(4), rng.bytes(64), rng.bytes(4096), rng.bytes(200_000)
    ]
  end

  def test_doc_methods_survive_garbage
    garbage_corpus.each do |bytes|
      doc = YrbLite::Doc.new
      safe { doc.apply_update(bytes) }
      safe { doc.sync_step2(bytes) }
      safe { doc.handle_sync_message(bytes) }
      safe { doc.encode_update_message(bytes) }
    end
    # Reaching here means nothing crashed the process; the runtime still works.
    assert_kind_of String, YrbLite::Doc.new.encode_state_vector
  end

  def test_awareness_methods_survive_garbage
    garbage_corpus.each do |bytes|
      awareness = YrbLite::Awareness.new
      safe { awareness.handle(bytes) }
      safe { awareness.apply_update(bytes) }
      safe { awareness.encode_update(bytes) }
      safe { awareness.update_from_message(bytes) }
      safe { awareness.awareness_client_ids(bytes) }
      safe { awareness.set_local_state(bytes) }
      safe { awareness.remove_clients([rand(1 << 32)]) }
    end

    assert_kind_of Integer, YrbLite::Awareness.new.client_id
  end

  def test_garbage_does_not_corrupt_a_good_document
    doc = YrbLite::Doc.new
    doc.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    good_state = doc.encode_state_as_update
    good_sv = doc.encode_state_vector

    garbage_corpus.each { |bytes| safe { doc.apply_update(bytes) } }

    assert_equal good_sv, doc.encode_state_vector,
                 "a failed/garbage apply must not mutate the document"
    assert_equal good_state, doc.encode_state_as_update
  end

  def test_document_still_usable_after_garbage
    doc = YrbLite::Doc.new
    garbage_corpus.each { |bytes| safe { doc.apply_update(bytes) } }

    # A valid update after all that garbage must still apply cleanly.
    doc.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    other = YrbLite::Doc.new
    other.apply_update(doc.encode_state_as_update)

    assert_equal doc.encode_state_vector, other.encode_state_vector
  end

  def test_message_kind_accepts_clean_messages_and_rejects_unsafe_frames
    aw = YrbLite::Awareness.new

    # Valid, single, well-formed messages get a real kind.
    assert_equal 1, aw.message_kind(YrbLite::Doc.new.sync_step1), "sync step1"
    update = aw.encode_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)

    assert_equal 2, aw.message_kind(update), "document update"
    presence = YrbLite::Awareness.new
    presence.set_local_state('{"u":1}')
    awareness_msg = presence.encode_awareness_update

    assert_equal 3, aw.message_kind(awareness_msg), "awareness"

    # Anything an attacker could relay through must be dropped (0).
    assert_equal 0, aw.message_kind(""), "empty"
    assert_equal 0, aw.message_kind("\xff\xff\xff".b), "garbage"
    assert_equal 0, aw.message_kind("\x63\x63\x63".b), "unknown type"
    assert_equal 0, aw.message_kind(update + awareness_msg), "two messages packed together"
    assert_equal 0, aw.message_kind(update + "\xde\xad".b), "trailing garbage"
    assert_equal 0, aw.message_kind(update[0...(update.length / 2)]), "truncated message"
  end

  private

  # Run a native call that may legitimately reject bad input. Success or a
  # Ruby-level StandardError are both fine; a process crash would never reach
  # the next line, and a non-StandardError (e.g. a fatal) would fail the test.
  def safe
    yield
  rescue StandardError
    # expected for malformed input
  end
end
