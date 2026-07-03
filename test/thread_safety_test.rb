# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "json"

# Thread-safety regression tests.
#
# yrs::Doc is Send + Sync, with an internal blocking RwLock around every
# transaction, and the extension adds no RefCell or other interior mutability.
# A compile-time assertion in lib.rs checks Doc is Send + Sync.
#
# These tests hammer a shared Doc from many Ruby threads. The extension releases
# the GVL for the native CRDT work, so threads genuinely run concurrently inside
# apply/encode; it's yrs's RwLock, not the GVL, that serializes mutations on the
# same doc. They guard against regressions (e.g. reintroducing a RefCell whose
# re-entrant borrow would panic and kill the process) and verify CRDT
# convergence is unaffected by interleaving.
class ThreadSafetyTest < Minitest::Test
  THREADS = 8
  ITERATIONS = 50

  def test_concurrent_writes_and_reads_on_shared_doc
    doc = Y::Doc.new
    updates = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_threads do |i|
      ITERATIONS.times do
        if i.even?
          doc.apply_update(updates[(i / 2) % updates.length])
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
    sequential = Y::Doc.new
    updates.each { |u| sequential.apply_update(u) }

    assert_equal sequential.encode_state_vector, doc.encode_state_vector
    assert_equal sequential.encode_state_as_update, doc.encode_state_as_update
  end

  def test_concurrent_sync_protocol_between_doc_pairs
    pairs = THREADS.times.map do
      source = Y::Doc.new
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
      source.apply_update(YjsFixtures::TwoDocsMerged::DOC2_UPDATE)
      [source, Y::Doc.new]
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

  def test_concurrent_read_text_with_writers_does_not_deadlock
    # Regression: read_text used to open a second read transaction while still
    # holding the first (a chained temporary). yrs's lock is write-preferring, so
    # a writer arriving between the two acquisitions deadlocked reader-vs-writer
    # inside nogvl — uninterruptibly. With the fix this completes; without it,
    # this test hangs (CI timeout catches it).
    doc = Y::Doc.new
    doc.apply_update(YjsFixtures::TextHelloWorld::UPDATE)
    updates = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_threads do |i|
      ITERATIONS.times do
        if i.even?
          doc.read_text("content")
        else
          doc.apply_update(updates[(i / 2) % updates.length])
        end
      end
    end

    assert_empty errors
    refute_nil doc.read_text("content")
  end

  def test_concurrent_lexical_to_html_with_writers_does_not_deadlock
    # Y::Lexical holds an Arc handle to the same doc, so its renders contend
    # with writers on the doc's RwLock. Same guarantees as every other native
    # op: one transaction per call, opened inside nogvl — this hammer both
    # proves it under contention and would hang (CI timeout) if a future edit
    # reintroduced a nested transaction in the render path.
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.expand_path("../ext/yrby/src/fixtures/lexxy_full.bin", __dir__)))
    lexical = Y::Lexical.new(doc)
    updates = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_threads do |i|
      ITERATIONS.times do
        if i.even?
          html = lexical.to_html

          raise "render lost content under contention" unless html&.include?("<h1>Heading One</h1>")
        else
          # Writers hit a different root of the SAME doc: full write-lock
          # contention against the renders without perturbing the Lexical root.
          doc.apply_update(updates[(i / 2) % updates.length])
        end
      end
    end

    assert_empty errors
    assert_includes lexical.to_html, "</action-text-attachment>"
  end

  def test_concurrent_fan_in_sync_to_shared_doc
    # Many threads sync different sources into ONE shared doc concurrently.
    shared = Y::Doc.new
    sources = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    ]

    errors = run_threads do |i|
      update = sources[i % sources.length]
      ITERATIONS.times do
        message = Y.wrap_update(update)
        shared.handle_sync_message(message)
      end
    end

    assert_empty errors

    # Compare against sequential application (state vector bytes aren't
    # canonical across implementations, so compare via our own encoding).
    sequential = Y::Doc.new
    sources.each { |u| sequential.apply_update(u) }

    assert_equal sequential.encode_state_vector, shared.encode_state_vector
    assert_equal sequential.encode_state_as_update, shared.encode_state_as_update
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
