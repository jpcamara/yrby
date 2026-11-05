# frozen_string_literal: true

require "test_helper"
require "timeout"

# Doc#edit is the unit a long-lived process saves and broadcasts as it
# streams into a document: every local write no edit has returned yet, or
# nil for none.
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

  # Writes made outside an edit wait for the next one, so none is left out.
  def test_writes_made_before_an_edit_come_with_it
    doc = Y::Doc.new
    text = doc.get_text("t")
    text << "abc"
    text.delete(0, 1)
    peer = Y::Doc.new
    peer.apply_update(doc.edit { text << "d" })

    assert_equal "bcd", peer.read_text("t")
    assert_nil(doc.edit { text.to_s })
  end

  # A block that raises leaves its writes for the next edit.
  def test_writes_from_a_block_that_raised_come_with_the_next_edit
    doc = Y::Doc.new
    text = doc.get_text("t")
    assert_raises(RuntimeError) do
      doc.edit do
        text << "kept"
        raise "stop"
      end
    end
    fresh = Y::Doc.new
    fresh.apply_update(doc.edit { text << " then" })

    assert_equal "kept then", fresh.read_text("t")
  end

  def test_a_chunk_stays_small_however_much_was_deleted_before
    doc = Y::Doc.new
    text = doc.get_text("t")
    200.times do |i|
      text << "x#{i} "
      text.delete(text.length - 2, 1)
    end
    doc.edit { nil } # takes the writes above

    assert_operator doc.edit { text << "y" }.bytesize, :<, 40
  end

  # A peer's update applied during the block stays out. A write another
  # thread or fiber makes meanwhile comes with it, so none is left out.
  def test_a_peers_update_stays_out_and_every_local_write_comes_with_it
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
    assert_equal "other thread, other fiber", fresh.read_text("other")
  end

  # Edits on several threads at once each take what's unsent, and together
  # their updates hold every write with nothing left pending.
  def test_edits_on_several_threads_at_once_lose_nothing
    doc = Y::Doc.new
    text = doc.get_text("t")
    updates = Queue.new
    threads = Array.new(4) do
      Thread.new do
        200.times do
          update = doc.edit { text << "x" }
          updates << update if update
        end
      end
    end
    threads.each(&:join)
    fresh = Y::Doc.new
    fresh.apply_update(updates.pop) until updates.empty?

    assert_equal 800, fresh.read_text("t").length
    refute_predicate fresh, :pending?
  end

  # An interrupt landing anywhere in an edit leaves its update in the
  # document for the next edit, so the updates edits return hold every write.
  def test_an_interrupt_anywhere_in_an_edit_loses_no_update
    doc = Y::Doc.new
    text = doc.get_text("t")
    sent = []
    2000.times do
      Thread.handle_interrupt(Object => :never) do
        update = Thread.handle_interrupt(Object => :immediate) do
          Timeout.timeout(0.00002) { doc.edit { text << "a" } }
        end
        sent << update if update
      rescue Timeout::Error
        nil
      end
    end
    sent << doc.edit { nil }
    fresh = Y::Doc.new
    sent.compact.each { |update| fresh.apply_update(update) }

    assert_equal text.to_s, fresh.read_text("t")
    refute_predicate fresh, :pending?
  end

  # An edit in a fiber or thread the block starts counts as nested, so the
  # outer edit returns its writes too.
  def test_an_edit_in_a_fiber_or_thread_the_block_starts_is_nested
    doc = Y::Doc.new
    text = doc.get_text("t")
    outer = doc.edit do
      Enumerator.new { |y| y << doc.edit { text << "fiber " } }.next
      Thread.new { doc.edit { text << "thread" } }.join
    end
    fresh = Y::Doc.new
    fresh.apply_update(outer)

    assert_equal "fiber thread", fresh.read_text("t")
  end

  def test_a_frozen_document_can_still_be_edited
    doc = Y::Doc.new
    text = doc.get_text("t")
    doc.freeze
    fresh = Y::Doc.new
    fresh.apply_update(doc.edit { text << "x" })

    assert_equal "x", fresh.read_text("t")
  end

  # An edit inside another returns what's unsent so far, and the outer edit
  # returns it again.
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

  # A write to another document, or another document's edit, inside an edit
  # belongs to that document, not to this edit's update.
  def test_writes_to_another_document_stay_out_of_the_edit
    a = Y::Doc.new
    b = Y::Doc.new
    inner = nil
    outer = a.edit do
      a.get_text("t") << "a"
      b.get_text("loose") << "b"
      inner = b.edit { b.get_text("u") << "b" }
    end
    fresh = Y::Doc.new
    fresh.apply_update(outer)
    other = Y::Doc.new
    other.apply_update(inner)

    assert_equal "a", fresh.read_text("t")
    assert_nil fresh.read_text("u")
    assert_nil fresh.read_text("loose")
    assert_equal "b", other.read_text("u")
  end

  # An inner edit that raises leaves its writes for the outer one.
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
