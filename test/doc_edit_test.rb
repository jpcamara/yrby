# frozen_string_literal: true

require "test_helper"

# Doc#edit is the unit a long-lived process saves and broadcasts as it
# streams into a document: the update the block produced, or nil for none.
class DocEditTest < Minitest::Test
  def test_the_update_the_block_produced_applies_on_a_peer
    doc = Y::Doc.new
    Y::Lexical.append_paragraph(doc, "before")
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    update = doc.edit { |d| Y::Lexical.append_paragraph(d, "streamed") }
    peer.apply_update(update)

    assert_equal "before\nstreamed", peer.read_xml("root")
  end

  def test_a_block_that_changes_nothing_yields_nil
    doc = Y::Doc.new

    assert_nil(doc.edit { |d| d.get_text("content") })
  end

  def test_successive_diffs_carry_only_their_own_chunk
    doc = Y::Doc.new
    block = nil
    setup = doc.edit { |d| block = Y::Lexical.append_paragraph(d, "") }
    first = doc.edit { block.insert(block.length, "one ") }
    second = doc.edit { block.insert(block.length, "two") }

    peer = Y::Doc.new
    [setup, first, second].each { |update| peer.apply_update(update) }

    assert_equal "one two", peer.read_xml("root")
    assert_operator second.bytesize, :<, doc.encode_state_as_update.bytesize,
                    "a diff is about its chunk, not the document"
  end

  def test_a_block_that_writes_nothing_is_nil_even_after_deletions
    doc = Y::Doc.new
    text = doc.get_text("t")
    text << "abc"
    text.delete(0, 1)

    assert_nil(doc.edit { text.to_s })
  end

  def test_a_chunk_stays_small_however_much_was_deleted_before
    doc = Y::Doc.new
    text = doc.get_text("t")
    200.times do |i|
      text << "x#{i} "
      text.delete(text.length - 2, 1)
    end

    assert_operator doc.edit { text << "y" }.bytesize, :<, 40
  end

  def test_applying_an_update_inside_the_block_raises
    doc = Y::Doc.new
    remote = Y::Doc.new
    remote.get_text("theirs") << "from a peer"

    error = assert_raises(Y::Error) do
      doc.edit { |d| d.apply_update(remote.encode_state_as_update) }
    end
    assert_match(/apply_update can.t run inside transact or edit/, error.message)
    doc.apply_update(remote.encode_state_as_update)

    assert_equal "from a peer", doc.read_text("theirs"), "the document is usable after"
  end

  # Another thread waits for the block to commit, so its write lands after
  # the edit and stays out of the update.
  def test_another_threads_write_waits_and_is_left_out
    doc = Y::Doc.new
    other = nil
    update = doc.edit do |d|
      other = Thread.new { d.get_text("theirs") << "other thread" }
      sleep 0.1

      assert_predicate other, :alive?, "the other thread waits for the commit"
      d.get_text("mine") << "this thread"
    end
    other.join(5) or flunk "the other thread never got the document"
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "", fresh.read_text("theirs").to_s
    assert_equal "this thread", fresh.read_text("mine")
    assert_equal "other thread", doc.read_text("theirs")
  end
end
