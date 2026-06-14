# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "yrb_lite/sync"

class SyncTest < Minitest::Test
  class SyncHelper
    include YrbLite::Sync
  end

  def setup
    @helper = SyncHelper.new
    YrbLite::Sync.reset!
  end

  def test_awareness_for_returns_same_instance_for_same_key
    a1 = YrbLite::Sync.awareness_for("test-room")
    a2 = YrbLite::Sync.awareness_for("test-room")

    assert_same a1, a2
  end

  def test_awareness_for_different_keys
    a1 = YrbLite::Sync.awareness_for("room-1")
    a2 = YrbLite::Sync.awareness_for("room-2")

    refute_same a1, a2
  end

  def test_awareness_for_applies_on_load_state_once
    source = YrbLite::Doc.new
    target = YrbLite::Doc.new
    source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    state = source.encode_state_as_update

    calls = 0
    loader = lambda do |key|
      calls += 1
      assert_equal "loaded-room", key
      state
    end

    awareness = YrbLite::Sync.awareness_for("loaded-room", loader)
    YrbLite::Sync.awareness_for("loaded-room", loader)

    assert_equal 1, calls, "on_load should run once per key"
    target.apply_update(awareness.encode_state_as_update)
    assert_equal source.encode_state_vector, target.encode_state_vector
  end

  def test_awareness_for_is_thread_safe_on_creation
    instances = 16.times.map do
      Thread.new { YrbLite::Sync.awareness_for("contended-room") }
    end.map(&:value)

    assert_equal 1, instances.uniq(&:object_id).length,
                 "Concurrent subscribers must share one document"
  end

  def test_reset_clears_registry
    YrbLite::Sync.awareness_for("room-1")
    refute_empty YrbLite::Sync.registry

    YrbLite::Sync.reset!

    assert_empty YrbLite::Sync.registry
  end

  def test_broadcast_classification
    sync_step1 = "\x00\x00\x01\x00".b
    sync_step2 = "\x00\x01\x01\x00".b
    sync_update = "\x00\x02\x01\x00".b
    awareness_update = "\x01\x01\x00".b
    query_awareness = "\x03".b

    refute @helper.send(:sync_broadcast?, sync_step1), "SyncStep1 is addressed to the server"
    assert @helper.send(:sync_broadcast?, sync_step2)
    assert @helper.send(:sync_broadcast?, sync_update)
    assert @helper.send(:sync_broadcast?, awareness_update)
    refute @helper.send(:sync_broadcast?, query_awareness)

    refute @helper.send(:sync_modifies_doc?, sync_step1)
    assert @helper.send(:sync_modifies_doc?, sync_step2)
    assert @helper.send(:sync_modifies_doc?, sync_update)
    refute @helper.send(:sync_modifies_doc?, awareness_update)
  end

  # -- Idle document eviction ----------------------------------------------

  def test_release_evicts_when_last_subscriber_leaves
    YrbLite::Sync.awareness_for("evict-room")
    YrbLite::Sync.subscribe("evict-room")
    YrbLite::Sync.subscribe("evict-room") # two subscribers

    saved = []
    refute YrbLite::Sync.release("evict-room", evictable: true) { |_a| saved << :save },
           "one subscriber remains — not evicted"
    assert YrbLite::Sync.registry.key?("evict-room")
    assert_empty saved

    assert YrbLite::Sync.release("evict-room", evictable: true) { |_a| saved << :save },
           "last subscriber left — evicted"
    refute YrbLite::Sync.registry.key?("evict-room")
    assert_equal [:save], saved, "persisted exactly once before eviction"
  end

  def test_release_keeps_document_when_not_evictable
    YrbLite::Sync.awareness_for("keep-room")
    YrbLite::Sync.subscribe("keep-room")

    refute YrbLite::Sync.release("keep-room", evictable: false)
    assert YrbLite::Sync.registry.key?("keep-room"),
           "with no on_load, unloading would lose data — keep it warm"
  end

  def test_eviction_aborts_if_a_subscriber_returns_during_persist
    YrbLite::Sync.awareness_for("race-room")
    YrbLite::Sync.subscribe("race-room")

    evicted = YrbLite::Sync.release("race-room", evictable: true) do |_a|
      YrbLite::Sync.subscribe("race-room") # someone reconnects mid-persist
    end

    refute evicted, "eviction must abort if a subscriber returned during persist"
    assert YrbLite::Sync.registry.key?("race-room")
  end

  # -- Authoritative (record-before-distribute) path -----------------------

  # Wrap a raw Y.js update as a MSG_SYNC/Update protocol frame in the JSON
  # envelope a client would send.
  def update_message(update_bytes)
    frame = YrbLite::Awareness.new.encode_update(update_bytes)
    { "m" => Base64.strict_encode64(frame) }
  end

  # A channel-like object with an on_change recorder, capturing transmits and
  # distributions instead of touching ActionCable. Fresh anonymous class per
  # call so on_change never leaks between tests.
  def authoritative_helper(key, broadcasts:, &recorder)
    klass = Class.new do
      include YrbLite::Sync
      attr_accessor :captured_broadcasts
      def transmit(_data); end
      define_method(:sync_distribute) { |encoded| @captured_broadcasts << encoded }
    end
    klass.on_change(&recorder)
    helper = klass.new
    helper.captured_broadcasts = broadcasts
    helper.instance_variable_set(:@sync_key, key)
    helper.instance_variable_set(:@sync_origin, "origin-#{key}")
    helper.instance_variable_set(:@sync_clients, [])
    helper
  end

  def test_on_change_records_exact_delta_before_apply_and_distribute
    key = "audit-room"
    broadcasts = []
    events = []
    recorder = lambda do |k, update|
      awareness = YrbLite::Sync.registry[k]
      events << {
        key: k,
        update: update.dup,
        sv_at_record: awareness.encode_state_vector,
        broadcasts_at_record: broadcasts.length
      }
    end

    helper = authoritative_helper(key, broadcasts: broadcasts, &recorder)
    empty_sv = YrbLite::Awareness.new.encode_state_vector
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))

    assert_equal 1, events.length, "recorder runs once per document change"
    event = events.first
    assert_equal key, event[:key]
    assert_equal YjsFixtures::TwoDocsMerged::DOC1_UPDATE, event[:update],
                 "the exact change delta is recorded"
    assert_equal empty_sv, event[:sv_at_record],
                 "document must NOT be modified before the change is recorded"
    assert_equal 0, event[:broadcasts_at_record],
                 "nothing may be distributed before the change is recorded"

    refute_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector,
                 "change is applied after recording"
    assert_equal 1, broadcasts.length, "change is distributed after recording"
  end

  def test_on_change_failure_rejects_change_entirely
    key = "reject-room"
    broadcasts = []
    recorder = ->(_k, _update) { raise "audit store unavailable" }

    helper = authoritative_helper(key, broadcasts: broadcasts, &recorder)
    empty_sv = YrbLite::Awareness.new.encode_state_vector

    assert_raises(RuntimeError) do
      helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))
    end

    assert_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector,
                 "a change that could not be recorded must not be applied"
    assert_empty broadcasts,
                 "a change that could not be recorded must not be distributed"
  end

  def test_on_change_ignores_non_document_messages
    key = "presence-room"
    recorded = []
    recorder = ->(_k, update) { recorded << update }
    helper = authoritative_helper(key, broadcasts: [], &recorder)

    # Awareness update (presence) and a SyncStep1 request are not document
    # changes — they must not hit the audit recorder.
    presence = YrbLite::Awareness.new
    presence.set_local_state('{"user":"alice"}')
    helper.sync_receive({ "m" => Base64.strict_encode64(presence.encode_awareness_update) })
    helper.sync_receive({ "m" => Base64.strict_encode64(YrbLite::Doc.new.sync_step1) })

    assert_empty recorded, "only document changes are recorded"
  end

  def test_no_op_change_is_not_recorded_or_distributed
    # The empty SyncStep2/Update a client sends during its opening handshake
    # carries no document change — it must not pollute the audit log or be
    # relayed.
    key = "noop-room"
    recorded = []
    broadcasts = []
    helper = authoritative_helper(key, broadcasts: broadcasts) { |_k, update| recorded << update }
    empty_sv = YrbLite::Awareness.new.encode_state_vector

    empty_update = YrbLite::Awareness.new.encode_update(YjsFixtures::EmptyDoc::UPDATE)
    helper.sync_receive({ "m" => Base64.strict_encode64(empty_update) })

    assert_empty recorded, "a no-op change must not be recorded"
    assert_empty broadcasts, "a no-op change must not be distributed"
    assert_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector
  end

  def test_unrecorded_change_is_invisible_to_concurrent_readers
    # The back door: other clients can read the server's document via a
    # sync/resync (SyncStep2 is computed from the doc's state vector). A change
    # still being recorded must not be visible through that path either — which
    # is why recording happens before the change is applied to the document.
    key = "backdoor-room"
    entered = Queue.new
    release = Queue.new
    recorder = lambda do |_k, _update|
      entered << true # we're inside the recorder, before apply
      release.pop      # block here until the test lets us finish
    end
    helper = authoritative_helper(key, broadcasts: [], &recorder)
    empty_sv = YrbLite::Awareness.new.encode_state_vector

    writer = Thread.new do
      helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))
    end

    entered.pop # recorder is now mid-write; the change is not yet recorded
    server = YrbLite::Sync.registry[key]
    assert_equal empty_sv, server.encode_state_vector,
                 "a change still being recorded must be invisible to a resync/read"

    release << true
    writer.join

    refute_equal empty_sv, server.encode_state_vector,
                 "once recorded, the change is applied and visible"
  end

  def test_change_records_on_redelivery_after_a_failure_heals
    # A transient store failure rejects the change; when the client re-offers
    # it (on resync/reconnect) and the store has recovered, it records and
    # applies normally — self-healing, no special handling.
    key = "self-heal-room"
    failing = true
    recorder = lambda do |_k, _update|
      raise "audit store unavailable" if failing
    end
    helper = authoritative_helper(key, broadcasts: [], &recorder)
    empty_sv = YrbLite::Awareness.new.encode_state_vector

    assert_raises(RuntimeError) do
      helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))
    end
    assert_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector,
                 "failed change is not applied"

    failing = false
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))
    refute_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector,
                 "the re-offered change records and applies after recovery"
  end

  def test_authoritative_path_is_a_total_order_under_concurrency
    key = "ordered-room"
    broadcasts_mutex = Mutex.new
    broadcasts = []
    log = []
    busy = false
    overlapped = false
    recorder = lambda do |_k, update|
      overlapped = true if busy
      busy = true
      log << update.dup
      Thread.pass # widen the window so a broken lock would overlap
      busy = false
    end

    frames = [
      YjsFixtures::TwoDocsMerged::DOC1_UPDATE,
      YjsFixtures::TwoDocsMerged::DOC2_UPDATE,
      YjsFixtures::TextHelloWorld::UPDATE,
      YjsFixtures::SyncProtocol::DIFF_UPDATE
    ]

    threads = 24.times.map do |i|
      Thread.new do
        helper = nil
        broadcasts_mutex.synchronize do
          helper = authoritative_helper(key, broadcasts: broadcasts, &recorder)
        end
        helper.sync_receive(update_message(frames[i % frames.length]))
      end
    end
    threads.each(&:join)

    refute overlapped, "recorder must never run concurrently for one document"
    assert_equal 24, log.length, "every change is recorded exactly once"

    # The authoritative document is exactly the in-order replay of the log.
    replay = YrbLite::Doc.new
    log.each { |update| replay.apply_update(update) }
    server = YrbLite::Sync.registry[key]
    assert_equal server.encode_state_vector, replay.encode_state_vector
    assert_equal server.encode_state_as_update, replay.encode_state_as_update,
                 "replaying the audit log reproduces the authoritative state"
  end

  def test_handle_sync_message_returns_tuple
    doc = YrbLite::Doc.new

    # Create a SyncStep1 message from another doc
    other_doc = YrbLite::Doc.new
    sync_step1 = other_doc.sync_step1

    result = doc.handle_sync_message(sync_step1)

    # Should return [msg_type, sync_type, response]
    assert result.is_a?(Array)
    assert_equal 3, result.length
    assert_equal 0, result[0] # MSG_SYNC
    assert_equal 0, result[1] # Responding to STEP1
    assert result[2].is_a?(String) # Response bytes (SyncStep2)
  end
end
