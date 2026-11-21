# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"

# Gappy updates are kept and served whole.
#
# An update whose causally-prior update is missing shows no content until
# that update arrives, and then heals. yrs doesn't reliably say when a doc
# is in that state, so nothing here asks: state is encoded and served
# losslessly, as Y.js servers do, and a peer heals the same way.
class PendingTest < Minitest::Test
  FIRST = YjsFixtures::Gap::FIRST
  DEPENDENT = YjsFixtures::Gap::DEPENDENT
  DEPENDENT_OTHER = YjsFixtures::Gap::DEPENDENT_OTHER
  PENDING_DELETE = YjsFixtures::PendingDelete::UPDATE

  def test_a_gappy_update_shows_nothing_until_its_dependency_arrives
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT) # depends on the missing FIRST

    assert_nil doc.read_text("notepad")

    doc.apply_update(FIRST)

    assert_equal "ab", doc.read_text("notepad")
  end

  # yrs doesn't report this gap as pending or advance the state vector for
  # it: the update skips ahead of its client's clock while the structs it
  # attaches to are present. The doc still converges once the skipped edit
  # arrives.
  def test_an_update_ahead_of_its_clients_clock_heals
    source = Y::Doc.new
    text = source.get_text("t")
    text.insert(0, "hello world hello world")
    base = source.encode_state_as_update
    skipped = source.edit { text.insert(5, "AAA") }
    ahead = source.edit { text.insert(20, "BBB") }
    doc = Y::Doc.new
    doc.apply_update(base)
    doc.apply_update(ahead)
    doc.apply_update(skipped)

    assert_equal source.read_text("t"), doc.read_text("t")
  end

  def test_encoding_a_doc_with_a_gap_keeps_it
    doc = Y::Doc.new
    doc.apply_update(DEPENDENT)
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)
    peer.apply_update(FIRST)

    assert_equal "ab", peer.read_text("notepad")
  end

  def test_sync_step2_reply_carries_a_gap_which_heals
    server = Y::Doc.new
    server.apply_update(DEPENDENT)
    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_nil client.read_text("notepad")

    client.apply_update(FIRST)

    assert_equal "ab", client.read_text("notepad")
  end

  def test_sync_step2_delivers_real_content
    server = Y::Doc.new
    server.apply_update(YjsFixtures::TextHelloWorld::UPDATE)
    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_equal "hello world", client.read_text("content")
  end

  def test_sync_diff_to_an_up_to_date_peer_carries_the_gap
    server = Y::Doc.new
    server.apply_update(FIRST)
    server.apply_update(DEPENDENT_OTHER)
    peer = Y::Doc.new
    peer.apply_update(FIRST)
    reply = server.handle_sync_message(peer.sync_step1)[2]
    peer.handle_sync_message(reply)

    assert_equal "a", peer.read_text("notepad")
    assert_equal server.encode_state_as_update, peer.encode_state_as_update
  end

  def test_sync_step2_serves_an_orphan_deletion
    server = Y::Doc.new
    server.apply_update(PENDING_DELETE) # a deletion whose target is absent
    client = Y::Doc.new
    reply = server.handle_sync_message(client.sync_step1)[2]
    client.handle_sync_message(reply)

    assert_equal server.encode_state_as_update, client.encode_state_as_update
  end

  def test_applying_reports_whether_anything_changed
    doc = Y::Doc.new

    assert doc.apply_update(FIRST)
    refute doc.apply_update(FIRST), "applying it again changes nothing"
  end

  # --- merging bytes and reporting what applying changed ---

  def test_merge_updates_keeps_a_gap
    other = Y::Doc.new(99)
    other.get_text("content") << "hello world"
    merged = Y.merge_updates([DEPENDENT, other.encode_state_as_update])
    doc = Y::Doc.new
    doc.apply_update(merged)
    doc.apply_update(FIRST)

    assert_equal "ab", doc.read_text("notepad")
    assert_equal "hello world", doc.read_text("content")
  end

  def test_merge_updates_of_nothing_is_an_empty_update
    doc = Y::Doc.new

    refute doc.apply_update(Y.merge_updates([]))
  end

  def test_merge_updates_rejects_bytes_that_are_not_an_update
    assert_raises(Y::Error) { Y.merge_updates(["not an update"]) }
  end
end
