# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"

# Pending-struct handling and gap-free serving.
#
# A gappy update (one whose causally-prior update is missing) parks in yrs as a
# *pending* struct: the doc's integrated state stays empty, but the pending block
# is a recovery buffer that heals if the missing dependency later arrives.
#
# The danger is that `encode_state_as_update` merges pending back in, so serving
# that state hands a peer content it can't integrate -- the peer parks the same
# pending forever and the state-vector/content mismatch drives endless resync
# traffic. So the sync path and `compacted_state_update` must serve integrated
# state only, while `encode_state_as_update` stays lossless for raw recovery.
class PendingTest < Minitest::Test
  FIRST = YjsFixtures::Gap::FIRST
  DEPENDENT = YjsFixtures::Gap::DEPENDENT
  DEPENDENT_OTHER = YjsFixtures::Gap::DEPENDENT_OTHER
  PENDING_DELETE = YjsFixtures::PendingDelete::UPDATE

  # --- detection ---

  def test_clean_doc_is_not_pending
    doc = Y::Doc.new
    doc.apply_update(FIRST)

    refute_predicate doc, :pending?
  end

  def test_gappy_update_parks_as_pending
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT) # depends on the missing FIRST

    assert_predicate doc, :pending?
    assert_nil doc.read_text("notepad"), "no integrated content while pending"
  end

  def test_pending_clears_once_the_missing_dependency_arrives
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT)
    doc.apply_update(FIRST)

    refute_predicate doc, :pending?, "gap healed"
    assert_equal "ab", doc.read_text("notepad")
  end

  # --- compacted_state_update (gap-free full state) ---

  def test_compacted_matches_full_encode_when_clean
    doc = Y::Doc.new
    doc.apply_update(FIRST)

    assert_equal doc.encode_state_as_update, doc.compacted_state_update
  end

  def test_compacted_excludes_pending_while_encode_keeps_it
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT)

    full = doc.encode_state_as_update
    compacted = doc.compacted_state_update

    refute_equal full, compacted, "compacted drops the pending bytes"

    # The lossless encode still round-trips the pending (recovery); the compacted
    # one does not poison a fresh peer.
    lossless_peer = Y::Doc.new
    lossless_peer.apply_update(full)

    assert_predicate lossless_peer, :pending?, "encode_state_as_update preserved the pending"

    clean_peer = Y::Doc.new
    clean_peer.apply_update(compacted)

    refute_predicate clean_peer, :pending?, "compacted_state_update carried no pending"
  end

  def test_compacted_is_non_destructive
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT)
    doc.compacted_state_update

    assert_predicate doc, :pending?, "compacting did not mutate the source doc"
  end

  def test_compacted_serves_content_once_healed
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT)
    doc.apply_update(FIRST)

    peer = Y::Doc.new
    peer.apply_update(doc.compacted_state_update)

    assert_equal "ab", peer.read_text("notepad")
  end

  # --- the sync path serves lossless state, like Y.js ---

  def test_sync_step2_reply_carries_pending_which_heals
    # A server whose stored state contains a gappy update.
    server = Y::Doc.new
    server.apply_update(DEPENDENT)

    # A fresh client announces its (empty) state; the server answers SyncStep2
    # with full state, pending included. The client parks it as the server did
    # and heals once the missing dependency arrives.
    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_predicate client, :pending?, "the pending struct traveled with the state"
    client.apply_update(FIRST)

    refute_predicate client, :pending?, "and healed once the dependency arrived"
    assert_equal "ab", client.read_text("notepad")
  end

  def test_sync_step2_still_delivers_real_content
    server = Y::Doc.new
    server.apply_update(YjsFixtures::TextHelloWorld::UPDATE)

    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_equal "hello world", client.read_text("content")
  end

  # --- mixed: real integrated content AND a pending struct together ---

  def test_compacted_keeps_content_and_drops_pending_when_mixed
    doc = Y::Doc.new
    doc.apply_update(FIRST)           # integrated "a"
    doc.apply_update(DEPENDENT_OTHER) # + a pending struct from another client

    assert_predicate doc, :pending?
    assert_equal "a", doc.read_text("notepad"), "only the integrated content is visible"

    peer = Y::Doc.new
    peer.apply_update(doc.compacted_state_update)

    assert_equal "a", peer.read_text("notepad"), "kept the real content"
    refute_predicate peer, :pending?, "dropped the pending"
  end

  def test_sync_diff_to_an_up_to_date_peer_carries_the_pending
    # Server has integrated content + pending; a peer that already has the
    # content asks for a diff. The diff includes the pending struct, so the
    # peer holds the same recovery buffer the server does.
    server = Y::Doc.new
    server.apply_update(FIRST)
    server.apply_update(DEPENDENT_OTHER)

    peer = Y::Doc.new
    peer.apply_update(FIRST) # already up to date on integrated state
    reply = server.handle_sync_message(peer.sync_step1)[2]
    peer.handle_sync_message(reply)

    assert_equal "a", peer.read_text("notepad")
    assert_predicate peer, :pending?, "the diff carried the pending recovery buffer"
  end

  # --- pending delete set (delete-side counterpart) ---

  def test_pending_delete_set_is_detected_and_not_served
    doc = Y::Doc.new
    doc.apply_update(PENDING_DELETE) # a deletion whose target struct is absent

    assert_predicate doc, :pending?, "an orphan deletion parks as a pending delete set"

    peer = Y::Doc.new
    peer.apply_update(doc.compacted_state_update)

    refute_predicate peer, :pending?, "the pending delete set was not served"
    assert_predicate doc, :pending?, "non-destructive: source keeps its pending"
  end

  def test_sync_step2_serves_a_pending_delete_set_too
    server = Y::Doc.new
    server.apply_update(PENDING_DELETE)

    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_predicate client, :pending?, "the pending delete set traveled with the state"
  end

  # --- thread safety of the new readers (match the nogvl model) ---

  def test_pending_and_compacted_are_thread_safe_under_contention
    doc = Y::Doc.new
    doc.apply_update(FIRST)
    doc.apply_update(DEPENDENT_OTHER) # holds pending, so the slow prune path runs
    errors = Queue.new

    threads = 8.times.map do
      Thread.new do
        50.times do
          doc.pending?
          doc.compacted_state_update
          doc.encode_state_as_update
        end
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)

    assert_empty([].tap { |a| a << errors.pop until errors.empty? })
    assert_predicate doc, :pending?, "reads left the doc unchanged"
  end
end
