# frozen_string_literal: true

# test/thread_safety_test.rb's interrupt tests, written against Y::Text so
# they run on the spike's C build too (its slice has no Y::Map). Run under
# both builds:
#   bundle exec ruby -Ilib -Itest bench/no_magnus/slice_interrupt_test.rb
#   YRBY_NATIVE=c bundle exec ruby -Ilib -Itest bench/no_magnus/slice_interrupt_test.rb
require "test_helper"

class SliceInterruptTest < Minitest::Test
  class Interrupted < StandardError; end

  def test_an_interrupt_raises_after_the_call_finishes
    text = Y::Doc.new.get_text("t")

    assert_raises(Interrupted) do
      Thread.handle_interrupt(Interrupted => :on_blocking) do
        Thread.current.raise(Interrupted)
        text << "n"
      end
    end
    assert_equal "n", text.to_s
  end

  def test_queued_interrupts_reach_a_thread_that_only_calls_yrby
    text = Y::Doc.new.get_text("t")
    looping = Queue.new
    worker = Thread.new do
      loop do
        text.clear
        text << "n"
        looping << true if looping.empty?
      end
    rescue Interrupted
      retry
    end
    looping.pop
    2_000.times do
      worker.raise(Interrupted)
      Thread.pass
    end
    worker.kill

    assert worker.join(5), "the kill never reached the worker"
  end

  def test_an_interrupt_during_take_unsent_keeps_the_update
    doc = Y::Doc.new
    text = doc.get_text("t")
    text << "kept"
    assert_raises(Interrupted) do
      Thread.handle_interrupt(Interrupted => :on_blocking) do
        Thread.current.raise(Interrupted)
        doc.send(:native_take_unsent)
      end
    end
    peer = Y::Doc.new
    peer.apply_update(doc.send(:native_take_unsent))
    assert_equal "kept", peer.read_text("t")
  end

  def test_an_unfrozen_input_changed_by_another_thread_is_safe
    doc = Y::Doc.new
    source = Y::Doc.new
    source.get_text("t") << ("x" * 10_000)
    update = +source.encode_state_as_update
    mutator = Thread.new { 200.times { update.replace(update.b) } }
    200.times { doc.apply_update(update) }
    mutator.join
    assert_equal 10_000, doc.get_text("t").length
  end
end
