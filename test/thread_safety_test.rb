# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "json"

# Thread-safety regression tests.
#
# The native types are thread-safe by construction: yrs::Doc is Send + Sync
# (internal blocking RwLock around every transaction) and yrs Awareness uses
# a concurrent map. There is no RefCell/interior-mutability in the extension,
# and a compile-time assertion in lib.rs proves Send + Sync for both types.
#
# These tests hammer shared instances from many Ruby threads. Under MRI the
# GVL serializes native calls, so they primarily guard against regressions
# (e.g. reintroducing a RefCell whose re-entrant borrow would panic and kill
# the process) and verify CRDT convergence is unaffected by interleaving.
class ThreadSafetyTest < Minitest::Test
  THREADS = 8
  ITERATIONS = 50

  def test_concurrent_writes_and_reads_on_shared_doc
    doc = YrbLite::Doc.new
    updates = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE,
      YjsFixtures::ProseMirrorDoc::UPDATE
    ]

    errors = run_threads do |i|
      ITERATIONS.times do
        if i.even?
          doc.apply_update(updates[i % updates.length])
        else
          doc.encode_state_vector
          doc.encode_state_as_update
          doc.sync_step1
        end
      end
    end

    assert_empty errors

    # CRDT convergence: interleaved/repeated application must equal
    # sequential application of the same updates.
    sequential = YrbLite::Doc.new
    updates.each { |u| sequential.apply_update(u) }
    assert_equal sequential.encode_state_vector, doc.encode_state_vector
    assert_equal sequential.encode_state_as_update, doc.encode_state_as_update
  end

  def test_concurrent_sync_protocol_between_doc_pairs
    pairs = THREADS.times.map do
      source = YrbLite::Doc.new
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC2_UPDATE)
      [source, YrbLite::Doc.new]
    end

    errors = run_threads do |i|
      source, target = pairs[i]
      ITERATIONS.times do
        # Full y-websocket handshake: target announces its state,
        # source responds with SyncStep2, target applies it.
        step1 = target.sync_step1
        _type, _sync_type, step2 = source.handle_sync_message(step1)
        target.handle_sync_message(step2)
      end
    end

    assert_empty errors
    pairs.each do |source, target|
      assert_equal source.encode_state_as_update, target.encode_state_as_update
    end
  end

  def test_concurrent_fan_in_sync_to_shared_doc
    # Many threads sync different sources into ONE shared doc concurrently.
    shared = YrbLite::Doc.new
    sources = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_threads do |i|
      update = sources[i % sources.length]
      ITERATIONS.times do
        message = shared.encode_update_message(update)
        shared.handle_sync_message(message)
      end
    end

    assert_empty errors

    # Compare against sequential application (state vector bytes aren't
    # canonical across implementations, so compare via our own encoding).
    sequential = YrbLite::Doc.new
    sources.each { |u| sequential.apply_update(u) }
    assert_equal sequential.encode_state_vector, shared.encode_state_vector
    assert_equal sequential.encode_state_as_update, shared.encode_state_as_update
  end

  def test_concurrent_awareness_state_changes
    awareness = YrbLite::Awareness.new

    errors = run_threads do |i|
      ITERATIONS.times do |j|
        awareness.set_local_state(JSON.generate({ "thread" => i, "tick" => j }))
        awareness.local_state
        awareness.encode_awareness_update
        awareness.encode_state_vector
      end
    end

    assert_empty errors
    final = JSON.parse(awareness.local_state)
    assert_includes 0...THREADS, final["thread"]
    assert_equal ITERATIONS - 1, final["tick"]
  end

  def test_concurrent_prosemirror_extraction
    doc = YrbLite::Doc.new
    doc.apply_update(YjsFixtures::ProseMirrorDoc::UPDATE)
    update = doc.encode_state_as_update

    errors = run_threads do
      ITERATIONS.times do
        from_doc = YrbLite::ProseMirrorExtractor.extract_from_doc(doc)
        from_update = YrbLite::ProseMirrorExtractor.extract(update)
        raise "extraction mismatch" unless from_doc == from_update
      end
    end

    assert_empty errors
  end

  private

  # Run THREADS threads, collecting any exception raised in each.
  def run_threads
    errors = Queue.new
    THREADS.times.map do |i|
      Thread.new do
        yield i
      rescue StandardError => e
        errors << e
      end
    end.each(&:join)
    [].tap { |a| a << errors.pop until errors.empty? }
  end
end
