# frozen_string_literal: true

require "test_helper"

# Doc#diff is the unit a long-lived process records and broadcasts as it
# streams into a document: the update the block produced, or nil for none.
class DocDiffTest < Minitest::Test
  def test_the_update_the_block_produced_applies_on_a_peer
    doc = Y::Doc.new
    Y::Lexical.append_paragraph(doc, "before")
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    update = doc.diff { |d| Y::Lexical.append_paragraph(d, "streamed") }
    peer.apply_update(update)

    assert_equal "before\nstreamed", peer.read_xml("root")
  end

  def test_a_block_that_changes_nothing_yields_nil
    doc = Y::Doc.new

    assert_nil(doc.diff { |d| d.get_text("content") })
  end

  def test_successive_diffs_carry_only_their_own_chunk
    doc = Y::Doc.new
    block = nil
    setup = doc.diff { |d| block = Y::Lexical.append_paragraph(d, "") }
    first = doc.diff { block.insert(block.length, "one ") }
    second = doc.diff { block.insert(block.length, "two") }

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

    assert_nil(doc.diff { text.to_s })
  end

  def test_a_chunk_stays_small_however_much_was_deleted_before
    doc = Y::Doc.new
    text = doc.get_text("t")
    200.times do |i|
      text << "x#{i} "
      text.delete(text.length - 2, 1)
    end

    assert_operator doc.diff { text << "y" }.bytesize, :<, 40
  end

  def test_an_update_applied_during_the_block_is_left_out
    doc = Y::Doc.new
    remote = Y::Doc.new
    remote.get_text("theirs") << "from a peer"
    update = doc.diff do |d|
      d.apply_update(remote.encode_state_as_update)
      d.get_text("mine") << "from ruby"
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "", fresh.read_text("theirs").to_s
    assert_equal "from ruby", fresh.read_text("mine")
  end

  def test_another_threads_writes_are_left_out
    doc = Y::Doc.new
    update = doc.diff do |d|
      Thread.new { d.get_text("theirs") << "other thread" }.join
      d.get_text("mine") << "this thread"
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "", fresh.read_text("theirs").to_s
    assert_equal "this thread", fresh.read_text("mine")
  end
end
