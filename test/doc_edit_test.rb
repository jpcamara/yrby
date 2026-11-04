# frozen_string_literal: true

require "test_helper"
require "timeout"

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

  # The update holds only the block's own writes. A peer's update, or a
  # write from another thread or fiber, made meanwhile stays out.
  def test_writes_made_elsewhere_during_the_block_stay_out_of_the_update
    doc = Y::Doc.new
    remote = Y::Doc.new
    remote.get_text("theirs") << "from a peer"
    update = doc.edit do |d|
      d.apply_update(remote.encode_state_as_update)
      Thread.new { d.get_text("other") << "other thread" }.join
      Fiber.new { d.get_text("other") << ", other fiber" }.resume
      d.get_text("mine") << "from ruby"
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "from ruby", fresh.read_text("mine")
    assert_equal "", fresh.read_text("theirs").to_s
    assert_equal "", fresh.read_text("other").to_s
  end

  # Two threads editing the same document take turns, so neither edit's
  # writes land between the other's and each update holds its own.
  def test_edits_on_two_threads_take_turns
    doc = Y::Doc.new
    a = doc.get_text("a")
    b = doc.get_text("b")
    order = Queue.new
    started = Queue.new
    other = Thread.new do
      doc.edit do
        b << "b1"
        order << :b1
        started << true
        sleep 0.05
        b << "b2"
        order << :b2
      end
    end
    started.pop
    mine = doc.edit do
      a << "a1"
      order << :a1
    end
    theirs = other.value

    assert_equal %i[b1 b2 a1], Array.new(3) { order.pop }
    fresh = Y::Doc.new
    fresh.apply_update(theirs)
    fresh.apply_update(mine)

    assert_equal %w[a1 b1b2], [fresh.read_text("a"), fresh.read_text("b")]
    refute_predicate fresh, :pending?
  end

  # An edit inside another returns its own writes, and the outer edit holds
  # them too.
  def test_a_nested_edit_adds_its_writes_to_the_outer_one
    doc = Y::Doc.new
    text = doc.get_text("t")
    inner = nil
    outer = doc.edit do
      text << "outer "
      inner = doc.edit { text << "inner" }
    end

    alone = Y::Doc.new
    alone.apply_update(outer)

    assert_equal "outer inner", alone.read_text("t")
    refute_nil inner
  end

  # A write that raises partway is still reported to an outer edit, so the
  # outer update holds everything the document gained from it.
  def test_an_inner_edit_that_raises_still_reaches_the_outer_one
    doc = Y::Doc.new
    text = doc.get_text("t")
    outer = doc.edit do
      doc.edit do
        text << "kept"
        raise "stop"
      end
    rescue RuntimeError
      nil
    end
    fresh = Y::Doc.new
    fresh.apply_update(outer)

    assert_equal "kept", fresh.read_text("t")
  end

  def test_a_block_that_only_deletes_yields_its_deletion
    doc = Y::Doc.new
    text = doc.get_text("t")
    text << "abc"
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    peer.apply_update(doc.edit { text.delete(0, 1) })

    assert_equal "bc", peer.read_text("t")
  end

  # Timeouts that land anywhere in an edit leave the document usable.
  def test_timeouts_during_edits_leave_the_document_usable
    doc = Y::Doc.new
    text = doc.get_text("t")
    200.times do
      Timeout.timeout(0.0005) { loop { doc.edit { text << "a" } } }
    rescue Timeout::Error
      nil
    end

    update = doc.edit { text << "b" }
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    refute_nil update
    assert_equal text.to_s, peer.read_text("t")
  end
end
