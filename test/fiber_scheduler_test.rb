# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "async"
require "json"

# Fiber-scheduler tests — the Async/fiber analogue of thread_safety_test.rb.
#
# thread_safety_test.rb hammers the native types from OS threads. Here every
# native call runs inside an Async reactor (Fiber.scheduler installed), with
# many fibers multiplexed onto one thread and a cooperative reschedule between
# each native call, so the extension is repeatedly entered and exited across
# fiber context switches — the shape it runs in under Falcon.
#
# The extension releases the GVL around CRDT work. A fiber scheduler does not
# preempt at GVL boundaries (fibers are cooperative; the GVL release is
# invisible to the scheduler), so a native call always runs to completion before
# another fiber resumes — there is no re-entrancy mid-call. These tests verify
# the extension is nonetheless correct when a scheduler is installed: it never
# corrupts shared state, convergence is unaffected by fiber interleaving, and
# nothing about releasing the GVL upsets the reactor.
class FiberSchedulerTest < Minitest::Test
  FIBERS = 8
  ITERATIONS = 50

  def test_a_scheduler_is_actually_installed_and_fibers_interleave
    # Guard: if this regressed to running without a scheduler (or without real
    # interleaving) the rest of the file would be testing nothing.
    order = []
    Async do |task|
      refute_nil Fiber.scheduler, "expected a fiber scheduler inside Async"
      FIBERS.times.map do |i|
        task.async do
          2.times do
            order << i
            task.yield
          end
        end
      end.each(&:wait)
    end

    refute_equal order, order.sort, "fibers did not interleave"
  end

  def test_concurrent_writes_and_reads_on_shared_doc
    doc = Y::Doc.new
    updates = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_fibers do |i, _j|
      if i.even?
        doc.apply_update(updates[(i / 2) % updates.length])
      else
        doc.encode_state_vector
        doc.encode_state_as_update
        doc.sync_step1
      end
    end

    assert_empty errors

    # Convergence: interleaved/repeated application must equal sequential
    # application of the same updates.
    sequential = Y::Doc.new
    updates.each { |u| sequential.apply_update(u) }

    assert_equal sequential.encode_state_vector, doc.encode_state_vector
    assert_equal sequential.encode_state_as_update, doc.encode_state_as_update
  end

  def test_sync_handshake_between_fiber_pairs
    pairs = FIBERS.times.map do
      source = Y::Doc.new
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC2_UPDATE)
      [source, Y::Doc.new]
    end

    errors = run_fibers do |i, _j|
      source, target = pairs[i]
      # Full y-websocket handshake: target announces its state, source responds
      # with SyncStep2, target applies it.
      step1 = target.sync_step1
      _type, _sync_type, step2 = source.handle_sync_message(step1)
      target.handle_sync_message(step2)
    end

    assert_empty errors
    pairs.each do |source, target|
      assert_equal source.encode_state_as_update, target.encode_state_as_update
    end
  end

  def test_fan_in_sync_to_shared_doc
    # Many fibers sync different sources into ONE shared doc concurrently.
    shared = Y::Doc.new
    sources = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_fibers do |i, _j|
      message = Y.wrap_update(sources[i % sources.length])
      shared.handle_sync_message(message)
    end

    assert_empty errors
    sequential = Y::Doc.new
    sources.each { |u| sequential.apply_update(u) }

    assert_equal sequential.encode_state_vector, shared.encode_state_vector
    assert_equal sequential.encode_state_as_update, shared.encode_state_as_update
  end

  private

  # Run FIBERS concurrent fibers inside one Async reactor. Each runs ITERATIONS
  # passes of the block and cooperatively reschedules (task.yield) after each, so
  # native calls from different fibers interleave on the single reactor thread.
  # Returns any exceptions raised, mirroring thread_safety_test's run_threads.
  def run_fibers
    errors = []
    Async do |task|
      raise "no fiber scheduler installed" unless Fiber.scheduler

      FIBERS.times.map do |i|
        task.async do
          ITERATIONS.times do |j|
            yield i, j
            task.yield
          rescue StandardError => e
            errors << e
          end
        end
      end.each(&:wait)
    end
    errors
  end
end
