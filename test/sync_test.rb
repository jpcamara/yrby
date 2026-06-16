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

  # -- Store-backed (AnyCable-native) backend ------------------------------

  def store_backed_helper(loader:, recorder:, transmits:, broadcasts:)
    klass = Class.new do
      include YrbLite::Sync

      sync_backend :store
      attr_accessor :_t, :_b

      def transmit(data) = @_t << data
      define_method(:sync_distribute) { |encoded| @_b << encoded }
    end
    klass.on_load(&loader)
    klass.on_change(&recorder)
    helper = klass.new
    helper._t = transmits
    helper._b = broadcasts
    helper
  end

  def test_sync_backend_defaults_to_memory_and_is_settable
    klass = Class.new { include YrbLite::Sync }

    assert_equal :memory, klass.sync_backend
    klass.sync_backend :store

    assert_equal :store, klass.sync_backend
  end

  def test_store_backed_answers_sync_step1_from_the_store
    source = YrbLite::Doc.new
    source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    state = source.encode_state_as_update

    transmits = []
    broadcasts = []
    helper = store_backed_helper(loader: ->(_k) { state }, recorder: ->(_k, _u) {},
                                 transmits: transmits, broadcasts: broadcasts)

    # Client sends a SyncStep1 (empty state vector); server answers from store.
    step1 = YrbLite::Doc.new.sync_step1
    helper.sync_receive({ "update" => Base64.strict_encode64(step1) }, "doc-key")

    assert_equal 1, transmits.length, "the SyncStep1 was answered"
    response = Base64.strict_decode64(transmits[0]["update"])
    delta = YrbLite::Awareness.new.update_from_message(response)
    rebuilt = YrbLite::Doc.new
    rebuilt.apply_update(delta)

    assert_equal source.encode_state_vector, rebuilt.encode_state_vector,
                 "the SyncStep2 carries the store's current state"
    assert_empty broadcasts, "a handshake request is not broadcast"
  end

  def test_store_backed_records_then_relays_an_update
    recorded = []
    broadcasts = []
    helper = store_backed_helper(loader: ->(_k) {}, recorder: ->(k, u) { recorded << [k, u] },
                                 transmits: [], broadcasts: broadcasts)

    msg = YrbLite::Awareness.new.encode_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    # The key is derived per-call (no instance var persists across AnyCable RPCs).
    helper.sync_receive({ "update" => Base64.strict_encode64(msg) }, "doc-key")

    assert_equal 1, recorded.length, "the change was recorded"
    assert_equal "doc-key", recorded[0][0]
    assert_equal YjsFixtures::TwoDocsMerged::DOC1_UPDATE, recorded[0][1], "the exact delta"
    assert_equal 1, broadcasts.length, "the change was relayed"
  end

  def test_store_backed_skips_no_op_updates
    recorded = []
    broadcasts = []
    helper = store_backed_helper(loader: ->(_k) {}, recorder: ->(_k, u) { recorded << u },
                                 transmits: [], broadcasts: broadcasts)

    empty = YrbLite::Awareness.new.encode_update(YjsFixtures::EmptyDoc::UPDATE)
    helper.sync_receive({ "update" => Base64.strict_encode64(empty) }, "doc-key")

    assert_empty recorded
    assert_empty broadcasts
  end

  # -- Multi-process replica sync ------------------------------------------

  def test_process_id_is_stable
    assert_kind_of String, YrbLite::Sync.process_id
    assert_equal YrbLite::Sync.process_id, YrbLite::Sync.process_id
  end

  def test_remote_change_is_applied_to_replica_without_recording
    key = "replica-room"
    recorded = []
    helper = authoritative_helper(key, broadcasts: []) { |_k, update| recorded << update }
    empty_sv = YrbLite::Awareness.new.encode_state_vector
    msg = YrbLite::Awareness.new.encode_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)

    # A change that arrived from another process (different pid) is applied to
    # the local replica but not re-recorded; its origin process already did.
    helper.send(:sync_on_broadcast,
                { "m" => Base64.strict_encode64(msg), "origin" => "other", "pid" => "process-b" })

    refute_equal empty_sv, YrbLite::Sync.registry[key].encode_state_vector,
                 "a remote process's change updates this process's replica"
    assert_empty recorded, "a remote change is not re-recorded here"
  end

  def test_own_process_broadcast_is_not_reapplied
    key = "own-pid-room"
    helper = authoritative_helper(key, broadcasts: [])
    sv_before = helper.sync_awareness.encode_state_vector # replica exists, empty
    msg = YrbLite::Awareness.new.encode_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)

    helper.send(:sync_on_broadcast,
                { "m" => Base64.strict_encode64(msg), "origin" => "x", "pid" => YrbLite::Sync.process_id })

    assert_equal sv_before, YrbLite::Sync.registry[key].encode_state_vector,
                 "a broadcast from this same process is not applied a second time"
  end

  # -- Idle document eviction ----------------------------------------------

  def test_release_evicts_when_last_subscriber_leaves
    YrbLite::Sync.awareness_for("evict-room")
    YrbLite::Sync.subscribe("evict-room")
    YrbLite::Sync.subscribe("evict-room") # two subscribers

    saved = []

    refute YrbLite::Sync.release("evict-room", evictable: true) { |_a| saved << :save },
           "one subscriber remains, so not evicted"
    assert YrbLite::Sync.registry.key?("evict-room")
    assert_empty saved

    assert YrbLite::Sync.release("evict-room", evictable: true) { |_a| saved << :save },
           "last subscriber left, so evicted"
    refute YrbLite::Sync.registry.key?("evict-room")
    assert_equal [:save], saved, "persisted exactly once before eviction"
  end

  def test_release_keeps_document_when_not_evictable
    YrbLite::Sync.awareness_for("keep-room")
    YrbLite::Sync.subscribe("keep-room")

    refute YrbLite::Sync.release("keep-room", evictable: false)
    assert YrbLite::Sync.registry.key?("keep-room"),
           "with no on_load, unloading would lose data, so keep it warm"
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

  # KNOWN GAP (currently failing): the authoritative path records the raw delta a
  # client sends without checking that it can integrate. If an earlier update
  # never reached the server (lost in a fire-and-forget send, or its record
  # failed), a later causally-dependent update is recorded against a log that's
  # missing its parent. Replaying that log can never integrate the later update
  # -- it stays a permanently-pending struct -- so the "complete, replayable
  # history" guarantee is broken. The fix: integrate, and if the update leaves
  # the doc pending, reject it (don't record, don't broadcast), reload from the
  # store, and force the client to resync so the missing piece comes back.
  def test_authoritative_rejects_update_that_cannot_integrate
    key = "causal-gap-room"
    recorded = []
    broadcasts = []
    helper = authoritative_helper(key, broadcasts: broadcasts) { |_k, u| recorded << u }

    # U1 ("A") integrates cleanly and is recorded.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1))
    # U2 ("B") never arrives -- simulate it lost in transit. U3 ("C") depends on
    # U2, so it cannot integrate against a log that holds only U1.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3))

    assert_equal [YjsFixtures::CausalChain::U1], recorded,
                 "U3 depends on a missing update and must not be recorded (causal gap)"
    assert_equal 1, broadcasts.length,
                 "U3 must not be distributed -- peers can't integrate it either"
  end

  def test_causal_gap_heals_after_the_client_resyncs
    key = "causal-heal-room"
    recorded = []
    transmits = []
    helper = authoritative_helper(key, broadcasts: []) { |_k, u| recorded << u }
    helper.define_singleton_method(:transmit) { |data| transmits << data }

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1)) # recorded
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3)) # rejected (gap)

    assert_equal 1, recorded.length, "the gappy update was not recorded"
    refute_empty transmits, "a resync (SyncStep1) was requested from the client"

    # The client resyncs: it re-sends everything the server is missing, as one
    # causally-complete delta (U2 + U3 merged) computed from the server's SV.
    client = YrbLite::Doc.new
    [YjsFixtures::CausalChain::U1, YjsFixtures::CausalChain::U2,
     YjsFixtures::CausalChain::U3].each { |u| client.apply_update(u) }
    server = YrbLite::Sync.registry[key]
    resync = client.encode_state_as_update(server.encode_state_vector)
    helper.sync_receive(update_message(resync))

    assert_equal 2, recorded.length, "the resync delta is recorded, gap-free"

    replay = YrbLite::Doc.new
    recorded.each { |u| replay.apply_update(u) }

    refute_predicate replay, :pending?, "the recorded log replays without a causal gap"
    assert_equal client.encode_state_as_update, replay.encode_state_as_update,
                 "replaying the log reconstructs the full document"
  end

  def test_store_backed_rejects_update_that_cannot_integrate
    log = []
    broadcasts = []
    loader = lambda do |_k|
      next nil if log.empty?

      doc = YrbLite::Doc.new
      log.each { |u| doc.apply_update(u) }
      doc.encode_state_as_update
    end
    helper = store_backed_helper(loader: loader, recorder: ->(_k, u) { log << u },
                                 transmits: [], broadcasts: broadcasts)
    msg = ->(bytes) { { "update" => Base64.strict_encode64(YrbLite::Awareness.new.encode_update(bytes)) } }

    helper.sync_receive(msg.call(YjsFixtures::CausalChain::U1), "k") # ready -> recorded
    helper.sync_receive(msg.call(YjsFixtures::CausalChain::U3), "k") # gap -> rejected

    assert_equal [YjsFixtures::CausalChain::U1], log,
                 "store mode must not append an update that can't integrate"
    assert_equal 1, broadcasts.length, "the gappy update is not relayed"
  end

  def test_on_change_ignores_non_document_messages
    key = "presence-room"
    recorded = []
    recorder = ->(_k, update) { recorded << update }
    helper = authoritative_helper(key, broadcasts: [], &recorder)

    # Awareness update (presence) and a SyncStep1 request aren't document
    # changes, so they must not hit the audit recorder.
    presence = YrbLite::Awareness.new
    presence.set_local_state('{"user":"alice"}')
    helper.sync_receive({ "m" => Base64.strict_encode64(presence.encode_awareness_update) })
    helper.sync_receive({ "m" => Base64.strict_encode64(YrbLite::Doc.new.sync_step1) })

    assert_empty recorded, "only document changes are recorded"
  end

  def test_no_op_change_is_not_recorded_or_distributed
    # The empty SyncStep2/Update a client sends during its opening handshake
    # carries no document change, so it must not land in the audit log or get
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
    # There's another way to observe a change: other clients can read the
    # server's document via a sync/resync, since SyncStep2 is computed from the
    # doc's state vector. A change still being recorded must not show up through
    # that path either. That's why recording happens before the change is
    # applied to the document.
    key = "backdoor-room"
    entered = Queue.new
    release = Queue.new
    recorder = lambda do |_k, _update|
      entered << true # we're inside the recorder, before apply
      release.pop # block here until the test lets us finish
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
    # A transient store failure rejects the change. When the client re-offers it
    # on resync/reconnect and the store has recovered, it records and applies
    # normally, with no special-case handling in between.
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

  # -- Reliable delivery (acks) --------------------------------------------

  # A fast-path channel-like object (no on_change) that captures transmits and
  # distributions. Used to observe acks without touching ActionCable.
  def fast_helper(key, transmits:, broadcasts:)
    klass = Class.new do
      include YrbLite::Sync

      attr_accessor :_t, :_b

      def transmit(data) = @_t << data
      define_method(:sync_distribute) { |encoded| @_b << encoded }
    end
    helper = klass.new
    helper._t = transmits
    helper._b = broadcasts
    helper.instance_variable_set(:@sync_key, key)
    helper.instance_variable_set(:@sync_origin, "origin-#{key}")
    helper.instance_variable_set(:@sync_clients, [])
    helper
  end

  def acks_in(transmits)
    transmits.filter_map { |t| t["ack"] if t.is_a?(Hash) && t.key?("ack") }
  end

  def test_fast_path_acks_an_applied_update_carrying_an_id
    transmits = []
    helper = fast_helper("ack-fast", transmits: transmits, broadcasts: [])

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE).merge("id" => 7))

    assert_equal [7], acks_in(transmits), "an applied update with an id is acked"
  end

  def test_authoritative_path_acks_a_recorded_update_carrying_an_id
    transmits = []
    recorded = []
    helper = authoritative_helper("ack-auth", broadcasts: []) { |_k, u| recorded << u }
    helper.define_singleton_method(:transmit) { |data| transmits << data }

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE).merge("id" => "abc"))

    assert_equal ["abc"], acks_in(transmits), "a recorded update with an id is acked"
  end

  def test_store_path_acks_a_recorded_update_carrying_an_id
    transmits = []
    helper = store_backed_helper(loader: ->(_k) {}, recorder: ->(_k, _u) {},
                                 transmits: transmits, broadcasts: [])
    msg = YrbLite::Awareness.new.encode_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)

    helper.sync_receive({ "update" => Base64.strict_encode64(msg), "id" => 42 }, "doc-key")

    assert_equal [42], acks_in(transmits), "store mode acks a recorded update with an id"
  end

  def test_no_ack_without_an_id
    # Stock clients send no id and must be completely unaffected -- no ack frame.
    transmits = []
    helper = fast_helper("no-ack", transmits: transmits, broadcasts: [])

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE))

    assert_empty acks_in(transmits), "an update without an id is never acked"
  end

  def test_gapped_update_is_not_acked
    # A causally-gapped update gets a resync, not an ack, so an ack-aware client
    # keeps retransmitting until the missing range lands and it can integrate.
    transmits = []
    helper = fast_helper("ack-gap", transmits: transmits, broadcasts: [])

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1).merge("id" => 1)) # ready
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3).merge("id" => 2)) # gap

    assert_equal [1], acks_in(transmits),
                 "only the integrable update is acked; the gapped one is not"
  end

  def test_no_op_update_is_not_acked
    # The empty SyncStep2 in an opening handshake carries no change; even with an
    # id, there's nothing to ack.
    transmits = []
    helper = fast_helper("ack-noop", transmits: transmits, broadcasts: [])

    empty = YrbLite::Awareness.new.encode_update(YjsFixtures::EmptyDoc::UPDATE)
    helper.sync_receive({ "m" => Base64.strict_encode64(empty), "id" => 9 })

    assert_empty acks_in(transmits), "a no-op update is not acked"
  end

  def test_handle_sync_message_returns_tuple
    doc = YrbLite::Doc.new

    # Create a SyncStep1 message from another doc
    other_doc = YrbLite::Doc.new
    sync_step1 = other_doc.sync_step1

    result = doc.handle_sync_message(sync_step1)

    # Should return [msg_type, sync_type, response]
    assert_kind_of Array, result
    assert_equal 3, result.length
    assert_equal 0, result[0] # MSG_SYNC
    assert_equal 0, result[1] # Responding to STEP1
    assert_kind_of String, result[2] # Response bytes (SyncStep2)
  end
end
