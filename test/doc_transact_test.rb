# frozen_string_literal: true

require "test_helper"
require "async"
require "json"
require "timeout"

# Doc#transact holds one write transaction across a block: its writes commit
# together, reads inside see them, and other threads wait for the commit.
# Doc#edit is the same transaction plus the update it made.
#
# Anything that could deadlock runs through `finishes`, so a hang fails the
# test instead of stopping the suite.
class DocTransactTest < Minitest::Test
  def finishes(seconds = 10)
    result = nil
    thread = Thread.new { result = yield }
    thread.join(seconds) or flunk "did not finish within #{seconds}s"
    result
  end

  def paragraphs(doc)
    root = doc.get_xml_text("root")
    blocks = []
    while (block = root.xml_text(blocks.length))
      blocks << block
    end
    blocks
  end

  # --- the block ---

  def test_returns_the_blocks_value_and_keeps_its_writes
    doc = Y::Doc.new
    value = doc.transact do |d|
      d.get_map("state")["a"] = 1
      :done
    end

    assert_equal :done, value
    assert_equal({ "a" => 1 }, doc.get_map("state").to_h)
  end

  def test_yields_the_receiver
    doc = Y::Doc.new
    map = doc.get_map("state")

    assert_same(doc, doc.transact { |d| d })
    assert_same(map, map.transact { |m| m })
  end

  def test_needs_a_block
    doc = Y::Doc.new

    assert_raises(ArgumentError) { doc.transact }
    assert_raises(ArgumentError) { doc.edit }
    assert_raises(ArgumentError) { doc.get_text("t").transact }
  end

  def test_a_nested_transact_joins_the_outer_one
    doc = Y::Doc.new
    update = doc.edit do |d|
      d.get_text("t") << "one "
      inner = d.transact do
        d.get_text("t") << "two "
        :inner
      end

      assert_equal :inner, inner
      Y::Lexical.append_paragraph(d, "three")
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "one two ", fresh.read_text("t")
    assert_equal "three", paragraphs(fresh).first.text
  end

  def test_a_handles_transact_joins_its_documents
    doc = Y::Doc.new
    text = doc.get_text("t")
    update = doc.edit do
      text.transact { text << "from the handle" }
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "from the handle", fresh.read_text("t")
  end

  def test_two_documents_hold_their_own_transactions
    a = Y::Doc.new
    b = Y::Doc.new
    finishes do
      a.transact do
        b.transact do
          a.get_text("t") << "a"
          b.get_text("t") << "b"
        end
        b.get_text("t") << "!"
      end
    end

    assert_equal "a", a.read_text("t")
    assert_equal "b!", b.read_text("t")
  end

  # --- reading inside the block ---

  def test_reads_inside_see_the_blocks_writes
    doc = Y::Doc.new
    seen = finishes do
      doc.transact do |d|
        d.get_map("state")["n"] = 1
        d.get_array("rows") << "r"
        d.get_text("t") << "text"
        block = Y::Lexxy.append_paragraph(d, "para")
        {
          map: d.get_map("state").to_h, array: d.get_array("rows").to_a, text: d.get_text("t").to_s,
          read_map: d.read_map("state"), read_text: d.read_text("t"), read_xml: d.read_xml("root"),
          html: Y::Lexxy.new(d).to_html, block_at: d.block_at(block.anchor), find: d.find(block.anchor)&.text,
          names: d.root_names.sort, update: d.encode_state_as_update.bytesize, vector: d.encode_state_vector.bytesize,
          pending: d.pending?, ready: d.update_ready?(d.encode_state_as_update),
          advances: d.update_advances?(d.encode_state_as_update), compacted: d.compacted_state_update.bytesize
        }
      end
    end

    assert_equal({ "n" => 1 }, seen[:map])
    assert_equal ["r"], seen[:array]
    assert_equal "text", seen[:text]
    assert_equal({ "n" => 1 }, JSON.parse(seen[:read_map]))
    assert_equal "text", seen[:read_text]
    assert_equal "para", seen[:read_xml]
    assert_equal "<p>para</p>", seen[:html]
    assert_equal 0, seen[:block_at]
    assert_equal "para", seen[:find]
    assert_equal %w[root rows state t], seen[:names]
    assert_operator seen[:update], :>, 2
    assert_operator seen[:vector], :>, 1
    refute seen[:pending]
    assert seen[:ready]
    refute seen[:advances], "the block's own state is already in the document"
    assert_operator seen[:compacted], :>, 2
  end

  def test_a_new_root_inside_the_block
    doc = Y::Doc.new
    finishes do
      doc.transact do |d|
        d.get_map("m")["k"] = "v"
        d.get_array("a") << 1
        d.get_text("t") << "x"
        d.get_xml_text("x").push_xml_text(Y::Lexical::PARAGRAPH_ATTRIBUTES)
      end
    end

    assert_equal %w[a m t x], doc.root_names.sort
  end

  # --- other threads ---

  def test_another_thread_waits_for_the_commit
    doc = Y::Doc.new
    other = nil
    doc.transact do |d|
      d.get_map("state")["mine"] = 1
      other = Thread.new { d.get_map("state")["theirs"] = 2 }
      sleep 0.2

      assert_predicate other, :alive?
      assert_equal({ "mine" => 1 }, d.get_map("state").to_h)
    end
    other.join(5) or flunk "the other thread never got the document"

    assert_equal({ "mine" => 1, "theirs" => 2 }, doc.get_map("state").to_h)
  end

  # A reader on another thread sees all of the block's writes or none.
  def test_another_thread_never_sees_the_block_half_done
    doc = Y::Doc.new
    keys = %w[a b c d e]
    done = false
    snapshots = []
    reader = Thread.new do
      snapshots << JSON.parse(doc.read_map("state") || "{}").keys.sort until done
    end
    100.times do |round|
      doc.transact do |d|
        keys.each do |key|
          d.get_map("state")[key] = round
          Thread.pass
        end
      end
      doc.transact { |d| d.get_map("state").clear }
      sleep 0.002 # lets the reader take a snapshot between rounds
    end
    done = true
    reader.join(5) or flunk "the reader never finished"

    assert_operator snapshots.length, :>, 10
    snapshots.uniq.each { |keys_seen| assert_includes [[], keys], keys_seen }
  end

  # The Lexical helpers write a block in one transaction, so a reader on
  # another thread never sees a block before its attributes or its text.
  # Each reader looks at every block the moment it appears.
  def test_a_reader_never_sees_a_paragraph_half_written
    doc = Y::Doc.new
    root = doc.get_xml_text("root")
    count = 300
    bad = Queue.new
    readers = 3.times.map do
      Thread.new do
        i = 0
        while i < count
          block = root.xml_text(i)
          next Thread.pass unless block

          seen = [block.attributes["__type"], block.text]
          bad << seen unless seen == ["paragraph", "para #{i} bold"]
          i += 1
        end
      end
    end
    count.times { |i| Y::Lexical.append_paragraph(doc, ["para #{i} ", { text: "bold", bold: true }]) }
    readers.each { |reader| reader.join(30) or flunk "a reader never finished" }

    assert_empty Array.new(bad.size) { bad.pop }.first(3)
    assert_equal count, paragraphs(doc).length
  end

  # Read, then write what was read: the block keeps another thread from
  # writing in between, so no increment is lost.
  def test_read_modify_write_in_a_block_loses_nothing
    doc = Y::Doc.new
    counter = doc.get_map("counter")
    counter["n"] = 0
    threads = 8.times.map do
      Thread.new do
        100.times { doc.transact { counter["n"] = counter["n"] + 1 } }
      end
    end
    threads.each { |thread| thread.join(30) or flunk "a writer never finished" }

    assert_equal 800, counter["n"]
  end

  def test_concurrent_edits_converge_on_a_peer
    doc = Y::Doc.new
    updates = Queue.new
    threads = 8.times.map do |t|
      Thread.new do
        50.times do |i|
          updates << doc.edit { |d| Y::Lexxy.append_markdown(d, "## #{t}-#{i}\n\nBody **#{t}** #{i}") }
        end
      end
    end
    threads.each { |thread| thread.join(60) or flunk "an editor never finished" }
    peer = Y::Doc.new
    peer.apply_update(updates.pop) until updates.empty?

    assert_equal 800, paragraphs(peer).length
    assert_equal Y::Lexxy.new(doc).to_html, Y::Lexxy.new(peer).to_html
    refute_predicate peer, :pending?
  end

  # apply_update_changes reports the blocks its own update touched, even
  # while another thread writes to the document.
  def test_apply_update_changes_reports_only_its_own_update
    doc = Y::Doc.new
    Y::Lexical.append_paragraph(doc, "first")
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)
    done = false
    writer = Thread.new { Y::Lexical.append_paragraph(doc, "local") until done }
    reports = 300.times.map do |i|
      update = peer.edit { |pd| pd.get_xml_text("root").xml_text(0).insert(-1, " #{i}") }
      doc.apply_update_changes(update, "root")
    end
    done = true
    writer.join(10) or flunk "the writer never finished"

    assert_equal [[0]], reports.uniq
  end

  # --- leaving the block ---

  def test_a_raise_keeps_the_writes_and_frees_the_document
    doc = Y::Doc.new
    assert_raises(RuntimeError) do
      doc.transact do |d|
        d.get_text("t") << "kept"
        raise "boom"
      end
    end
    finishes { Thread.new { doc.get_text("t") << " after" }.join }

    assert_equal "kept after", doc.read_text("t")
  end

  def test_a_raise_inside_a_nested_block_leaves_the_outer_one_holding
    doc = Y::Doc.new
    other = nil
    doc.transact do |d|
      begin
        d.transact { raise "inner" }
      rescue RuntimeError
        nil
      end
      other = Thread.new { d.get_text("t") << "theirs" }
      sleep 0.1

      assert_predicate other, :alive?, "the outer block still holds the document"
      d.get_text("t") << "mine "
    end
    other.join(5) or flunk "the other thread never got the document"

    assert_equal "mine theirs", doc.read_text("t")
  end

  def test_break_throw_and_next_leave_the_block_committed
    doc = Y::Doc.new
    text = doc.get_text("t")
    broke = doc.transact { text << "a"; break :broke } # rubocop:disable Style/Semicolon
    thrown = catch(:out) { doc.transact { text << "b"; throw :out, :thrown } } # rubocop:disable Style/Semicolon
    nexted = doc.transact { text << "c"; next :nexted } # rubocop:disable Style/Semicolon
    finishes { Thread.new { text << "d" }.join }

    assert_equal %i[broke thrown nexted], [broke, thrown, nexted]
    assert_equal "abcd", text.to_s
  end

  def test_a_killed_thread_frees_the_document
    doc = Y::Doc.new
    inside = Queue.new
    holder = Thread.new do
      doc.transact do |d|
        d.get_text("t") << "before the kill "
        inside << true
        sleep
      end
    end
    inside.pop
    holder.kill
    holder.join(5) or flunk "the holder never died"
    finishes { doc.get_text("t") << "after" }

    assert_equal "before the kill after", doc.read_text("t")
  end

  # --- what can't run inside ---

  def test_remote_updates_raise_inside_the_block
    doc = Y::Doc.new
    peer = Y::Doc.new
    peer.get_text("t") << "remote"
    update = peer.encode_state_as_update
    message = Y.wrap_update(update)

    finishes do
      doc.transact do |d|
        assert_raises(Y::Error) { d.apply_update(update) }
        assert_raises(Y::Error) { d.apply_update_changes(update, "root") }
        assert_raises(Y::Error) { d.handle_sync_message(message) }
      end
    end
    doc.apply_update(update)

    assert_equal "remote", doc.read_text("t")
  end

  def test_edit_raises_inside_another_block_on_the_same_document
    doc = Y::Doc.new
    other = Y::Doc.new

    finishes do
      assert_raises(Y::Error) { doc.transact { doc.edit { nil } } }
      assert_raises(Y::Error) { doc.edit { doc.edit { nil } } }
      assert_kind_of(String, doc.transact { other.edit { |o| o.get_text("t") << "x" } })
    end
  end

  def test_edit_returns_nil_when_nothing_changed
    doc = Y::Doc.new
    doc.get_text("t") << "x"

    assert_nil(doc.edit { |d| d.get_text("t").to_s })
    assert_nil(doc.edit { nil })
  end

  # --- fibers ---

  # A fiber the block resumes can't run while the block waits for it, so
  # it raises instead of waiting forever.
  def test_a_fiber_the_block_resumes_raises_instead_of_waiting
    doc = Y::Doc.new
    error = finishes do
      doc.transact do |d|
        d.get_text("t") << "block"
        Fiber.new { d.get_text("t") << "fiber" }.resume
      rescue Y::Error => e
        e
      end
    end

    assert_match(/another fiber/, error.message)
    assert_equal "block", doc.read_text("t")
  end

  # Under a scheduler, another task waits for the block, and the wait yields
  # to it. The block's update holds only its own writes.
  def test_tasks_under_a_scheduler_wait_for_the_block
    doc = Y::Doc.new
    update = finishes do
      Async do |task|
        editor = task.async do
          doc.edit do |d|
            d.get_text("t") << "a"
            task.yield
            d.get_text("t") << "c"
          end
        end
        writer = task.async { doc.get_text("t") << "b" }
        writer.wait
        editor.wait
      end.wait
    end
    fresh = Y::Doc.new
    fresh.apply_update(update)

    assert_equal "ac", fresh.read_text("t")
    assert_equal "acb", doc.read_text("t")
  end

  def test_a_remote_update_from_another_task_waits_for_the_block
    source = Y::Doc.new
    source.get_text("t") << "remote"
    remote = source.encode_state_as_update
    doc = Y::Doc.new
    finishes do
      Async do |task|
        task.async do
          doc.transact do |d|
            d.get_text("t") << "local"
            task.yield
          end
        end
        task.async { doc.apply_update(remote) }
      end.wait
    end

    assert_includes doc.read_text("t"), "local"
    assert_includes doc.read_text("t"), "remote"
  end

  # --- waiting ---

  def hold(doc, seconds)
    held = Queue.new
    thread = Thread.new do
      doc.transact do
        held << true
        sleep seconds
      end
    end
    held.pop
    thread
  end

  def test_a_wait_for_a_held_document_can_time_out
    doc = Y::Doc.new
    holder = hold(doc, 3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Timeout::Error) { Timeout.timeout(0.2) { doc.read_text("t") } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  ensure
    holder&.kill&.join
  end

  def test_a_thread_waiting_for_a_held_document_can_be_killed
    doc = Y::Doc.new
    holder = hold(doc, 3)
    waiter = Thread.new { doc.get_text("t") << "never" }
    sleep 0.05
    waiter.kill

    assert waiter.join(1), "the waiting thread did not die"
    holder.kill.join

    assert_equal "", doc.read_text("t").to_s
  end

  # Two threads nesting blocks on two documents in opposite orders wait on
  # each other. A timeout breaks the wait, and both documents are free after.
  def test_opposite_order_nesting_can_be_broken_by_a_timeout
    a = Y::Doc.new
    b = Y::Doc.new
    ready = Queue.new
    go = Queue.new
    threads = [[a, b], [b, a]].map do |first, second|
      Thread.new do
        Timeout.timeout(0.5) do
          first.transact do
            ready << true
            go.pop
            second.transact { :both }
          end
        end
      rescue Timeout::Error => e
        e
      end
    end
    2.times { ready.pop }
    2.times { go << true }
    results = finishes(5) { threads.map(&:value) }

    assert(results.any?(Timeout::Error), "neither wait was broken: #{results.inspect}")
    a.get_text("t") << "free"
    b.get_text("t") << "free"

    assert_equal "free", a.read_text("t")
    assert_equal "free", b.read_text("t")
  end

  # --- garbage collection ---

  def test_handles_made_and_collected_inside_a_block
    doc = Y::Doc.new
    finishes do
      doc.transact do |d|
        200.times do |i|
          d.get_map("state").get_map("nested") || (d.get_map("state")["nested"] = { "i" => i })
          Y::Lexical.append_paragraph(d, "p#{i}")
          GC.start if (i % 50).zero?
        end
        GC.compact if GC.respond_to?(:compact)
        d.get_map("state")["after"] = true
      end
    end

    assert_equal 200, paragraphs(doc).length
    assert doc.get_map("state")["after"]
  end
end
