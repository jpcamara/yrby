# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "y/action_cable"
require "logger"
require "digest"

class SyncTest < Minitest::Test
  def update_message(update_bytes, id: nil)
    frame = Y.wrap_update(update_bytes)
    { "update" => Base64.strict_encode64(frame) }.tap do |payload|
      payload["id"] = id unless id.nil?
    end
  end

  def doc_state(updates)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each { |u| doc.apply_update(u) }
    doc.encode_state_as_update
  end

  def helper_for(store: [], recorder: nil, transmits: [], broadcasts: [])
    test = self
    recorder ||= ->(_key, update) { store << update }
    loader = ->(_key) { test.doc_state(store) }
    klass = Class.new do
      include Y::ActionCable::Sync

      attr_accessor :transmits, :broadcasts, :streams, :logger

      def transmit(data) = transmits << data

      def stream_from(name, **opts, &)
        streams << [name, opts, !block_given?]
      end

      define_method(:sync_distribute) { |encoded| broadcasts << encoded }
    end
    klass.on_load(&loader)
    klass.on_change(&recorder)
    helper = klass.new
    helper.transmits = transmits
    helper.broadcasts = broadcasts
    helper.streams = []
    helper.logger = Logger.new(File::NULL) # a real channel always has one; discard by default
    helper
  end

  def acks_in(transmits)
    transmits.filter_map { |t| t["ack"] if t.is_a?(Hash) && t.key?("ack") }
  end

  def test_sync_requires_loader_and_recorder
    no_loader = Class.new do
      include Y::ActionCable::Sync

      on_change { |_key, _update| nil }
    end
    no_recorder = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| nil }
    end

    assert_match(/on_load/, assert_raises(Y::Error) { no_loader.new.sync_subscribed("doc") }.message)
    assert_match(/on_change/, assert_raises(Y::Error) { no_recorder.new.sync_subscribed("doc") }.message)
  end

  def test_config_is_inherited_by_subclasses
    base = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| nil }
      on_change { |_key, _update| nil }
    end
    sub = Class.new(base)

    refute_nil sub.on_load
    refute_nil sub.on_change
  end

  def test_max_frame_bytes_default_override_and_disable
    klass = Class.new { include Y::ActionCable::Sync }

    assert_equal Y::ActionCable::Sync::DEFAULT_MAX_FRAME_BYTES, klass.max_frame_bytes
    klass.max_frame_bytes 1024

    assert_equal 1024, klass.max_frame_bytes
    klass.max_frame_bytes nil

    assert_nil klass.max_frame_bytes
  end

  def test_sync_subscribed_uses_stateless_streams_and_answers_from_store
    store = [YjsFixtures::TwoDocsMerged::DOC1_UPDATE]
    helper = helper_for(store: store)
    helper.sync_subscribed("doc")

    assert_equal [["yrby:doc", {}, true]], helper.streams
    assert_equal 1, helper.transmits.length

    response = Base64.strict_decode64(helper.transmits.first["update"])

    assert_equal Y::ActionCable::Sync::MSG_KIND_SYNC_STEP1,
                 Y.message_kind(response)
  end

  def test_anycable_whisper_is_scoped_to_awareness_stream
    helper = helper_for
    helper.define_singleton_method(:whispers_to) { |_broadcasting| nil }
    helper.sync_subscribed("doc")

    assert_includes helper.streams, ["yrby:doc", {}, true],
                    "document stream has no whisper option"
    assert_includes helper.streams, ["yrby:doc:awareness", { whisper: true }, true],
                    "awareness stream is whisper-enabled"
  end

  def test_answers_sync_step1_from_the_store
    source = Y::Doc.new
    source.apply_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    transmits = []
    helper = helper_for(store: [YjsFixtures::TwoDocsMerged::DOC1_UPDATE], transmits: transmits)

    helper.sync_receive({ "update" => Base64.strict_encode64(Y::Doc.new.sync_step1) }, "doc-key")

    assert_equal 1, transmits.length
    response = Base64.strict_decode64(transmits.first["update"])
    delta = Y.update_from_message(response)
    rebuilt = Y::Doc.new
    rebuilt.apply_update(delta)

    assert_equal source.encode_state_vector, rebuilt.encode_state_vector
  end

  def test_sync_step1_is_answered_with_gap_free_state_from_the_store
    # A store holding a legacy gappy update: the loaded doc has a pending struct.
    # The concern must answer SyncStep1 with integrated-only state, so a client
    # applying the reply is not poisoned.
    transmits = []
    helper = helper_for(store: [YjsFixtures::Gap::DEPENDENT], transmits: transmits)

    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    assert_equal 2, transmits.length, "the reply, plus a SyncStep1 soliciting the missing dep"
    reply = Base64.strict_decode64(transmits.first["update"])
    client.handle_sync_message(reply)

    refute_predicate client, :pending?, "the concern served integrated-only state"
  end

  def test_records_then_relays_and_acks_update
    store = []
    recorded = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, recorder: lambda { |k, u|
      recorded << [k, u]
      store << u
    },
                        transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 7), "doc-key")

    assert_equal [["doc-key", YjsFixtures::TwoDocsMerged::DOC1_UPDATE]], recorded
    assert_equal 1, broadcasts.length
    assert_equal [7], acks_in(transmits)
  end

  def test_no_ack_without_id
    helper = helper_for

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE), "doc-key")

    assert_empty acks_in(helper.transmits)
  end

  def test_no_op_update_is_not_recorded_relayed_or_acked
    store = []
    recorded = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, recorder: lambda { |_k, u|
      recorded << u
      store << u
    },
                        transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::EmptyDoc::UPDATE, id: 9), "doc-key")

    assert_empty recorded
    assert_empty broadcasts
    assert_empty acks_in(transmits)
  end

  def test_records_relays_and_acks_a_gapped_update
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1, id: 1), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 2), "doc-key")

    assert_equal [YjsFixtures::CausalChain::U1, YjsFixtures::CausalChain::U3], store,
                 "the gapped update is taken into custody, not refused"
    assert_equal 2, broadcasts.length
    assert_equal [1, 2], acks_in(transmits), "and acked once durably recorded"
  end

  def test_a_gapped_retransmit_is_not_recorded_twice
    store = []
    recorded = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits,
                        recorder: lambda { |_k, u|
                          recorded << u
                          store << u
                        })
    msg = update_message(YjsFixtures::CausalChain::U3, id: 1)

    3.times { helper.sync_receive(msg, "doc-key") }

    assert_equal 1, recorded.length,
                 "on_change fires once per update, not once per retransmission"
    assert_equal [1, 1, 1], acks_in(transmits), "every retransmit is acked"
  end

  def test_gap_is_logged_and_fires_on_gap
    logged = []
    gaps = []
    helper = helper_for
    helper.class.on_gap { |key| gaps << key }
    helper.logger = capturing_logger(logged)
    helper.define_singleton_method(:sync_log_context) { "user=42" }

    # A gapped update: U3 with no U1/U2 in the store.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    gap = logged.find { |lvl, msg| lvl == :info && msg.include?("causal gap") }

    assert gap, "an accepted gap is logged at info so an unhealed one stays visible"
    assert_includes gap.last, "doc-key", "the log names the document"
    assert_includes gap.last, "user=42", "and includes sync_log_context"
    assert_equal ["doc-key"], gaps, "and the on_gap hook fires with the key"
  end

  def test_a_clean_update_does_not_fire_on_gap
    gaps = []
    helper = helper_for
    helper.class.on_gap { |key| gaps << key }

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 1), "doc-key")

    assert_empty gaps, "no gap, no signal"
  end

  def test_on_gap_hook_errors_do_not_break_frame_handling
    broadcasts = []
    transmits = []
    helper = helper_for(transmits: transmits, broadcasts: broadcasts)
    helper.class.on_gap { |_key| raise "metrics backend down" }

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 4), "doc-key")

    assert_equal 1, broadcasts.length, "the update was still relayed"
    assert_equal [4], acks_in(transmits), "and still acked"
  end

  def test_gap_is_not_observed_when_recording_fails
    gaps = []
    helper = helper_for(recorder: ->(_k, _u) { raise "store unavailable" })
    helper.class.on_gap { |key| gaps << key }

    assert_raises(RuntimeError) do
      helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    end

    assert_empty gaps, "a gap is observed only once it is durably recorded"
  end

  def test_gap_heals_after_client_resyncs
    store = []
    helper = helper_for(store: store)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")

    client = Y::Doc.new
    [YjsFixtures::CausalChain::U1, YjsFixtures::CausalChain::U2,
     YjsFixtures::CausalChain::U3].each { |u| client.apply_update(u) }
    server = Y::Doc.new
    store.each { |u| server.apply_update(u) }
    resync = client.encode_state_as_update(server.encode_state_vector)

    helper.sync_receive(update_message(resync), "doc-key")

    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }

    # Full-state equality proves the replay integrated everything: a leftover
    # pending struct would be absent from encode_state_as_update and diverge.
    assert_equal client.encode_state_as_update, replay.encode_state_as_update
  end

  def test_record_failure_rejects_change
    broadcasts = []
    helper = helper_for(recorder: ->(_key, _update) { raise "store unavailable" }, broadcasts: broadcasts)

    assert_raises(RuntimeError) do
      helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 5), "doc-key")
    end

    assert_empty broadcasts
    assert_empty acks_in(helper.transmits)
  end

  def test_block_recorder_runs_in_channel_instance_context
    seen = nil
    klass = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| nil }
      on_change { |_key, _update| seen = current_author }

      attr_accessor :transmits, :broadcasts

      def current_author = "user-42"
      def transmit(data) = transmits << data
      define_method(:sync_distribute) { |encoded| broadcasts << encoded }
    end
    helper = klass.new
    helper.transmits = []
    helper.broadcasts = []

    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE), "doc-key")

    assert_equal "user-42", seen
  end

  def test_loader_runs_in_channel_instance_context
    seen = nil
    klass = Class.new do
      include Y::ActionCable::Sync

      on_load do |_key|
        seen = current_author
        nil
      end
      on_change { |_key, _update| nil }

      attr_accessor :transmits, :broadcasts

      def current_author = "loader-42"
      def transmit(data) = transmits << data
      define_method(:sync_distribute) { |encoded| broadcasts << encoded }
    end
    helper = klass.new
    helper.transmits = []
    helper.broadcasts = []

    # sync_receive of a document update rebuilds the doc via sync_load_doc,
    # which invokes on_load, proving the loader runs in the channel's context.
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE), "doc-key")

    assert_equal "loader-42", seen
  end

  def test_awareness_frames_are_relayed_but_not_recorded
    recorded = []
    broadcasts = []
    helper = helper_for(recorder: ->(_key, update) { recorded << update }, broadcasts: broadcasts)

    helper.sync_receive({ "update" => Base64.strict_encode64(YjsFixtures::Presence::FRAME) }, "doc-key")

    assert_empty recorded
    assert_equal 1, broadcasts.length
  end

  def test_malformed_and_oversized_frames_are_dropped
    helper = helper_for
    helper.class.max_frame_bytes 4

    helper.sync_receive({ "update" => "not-base64", "id" => 1 }, "doc-key")
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 2), "doc-key")

    assert_empty helper.broadcasts
    assert_empty acks_in(helper.transmits)
  end

  # A logger that captures [level, message] pairs, resolving the lazy block form.
  def capturing_logger(sink)
    Object.new.tap do |logger|
      %i[warn debug info error].each do |level|
        logger.define_singleton_method(level) { |*args, &blk| sink << [level, blk ? blk.call : args.first] }
      end
    end
  end

  def test_dropped_frames_are_logged
    logged = []
    helper = helper_for
    helper.logger = capturing_logger(logged)

    # Oversized: logged at warn, naming the cap, the document key, and the
    # reliable-delivery id so the drop is traceable to a specific stuck update.
    helper.class.max_frame_bytes 4
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 2), "doc-key")

    warned = logged.any? do |lvl, msg|
      lvl == :warn && msg.include?("max_frame_bytes") && msg.include?("doc-key") && msg.include?("id=2")
    end

    assert(warned, "an oversized frame is logged at warn, naming the document and update")
    assert_empty acks_in(helper.transmits), "a dropped frame is still never acked"

    # Invalid base64 (cap disabled so the size check can't fire first): logged at
    # debug, still naming the document.
    logged.clear
    helper.class.max_frame_bytes nil
    helper.sync_receive({ "update" => "@@@bad", "id" => 3 }, "doc-key")

    assert(logged.any? { |lvl, msg| lvl == :debug && msg.include?("doc-key") },
           "an invalid-base64 frame is logged at debug, naming the document")
  end

  def test_drop_log_includes_sync_log_context
    logged = []
    helper = helper_for
    helper.logger = capturing_logger(logged)
    helper.define_singleton_method(:sync_log_context) { "user=42" }

    helper.class.max_frame_bytes 4
    helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 1), "doc-key")

    assert(logged.any? { |_lvl, msg| msg.include?("user=42") },
           "sync_log_context is appended to the drop log")
  end

  def test_drop_log_survives_a_raising_sync_log_context
    logged = []
    helper = helper_for
    helper.logger = capturing_logger(logged)
    helper.define_singleton_method(:sync_log_context) { raise "boom" }

    helper.class.max_frame_bytes 4
    # A broken context hook must not take down frame handling.
    assert_nil helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 1), "doc-key")
    assert(logged.any? { |_lvl, msg| msg.include?("log-context-error=RuntimeError") },
           "a raising context hook surfaces in the log instead of breaking the drop")
  end

  def test_lost_ack_retry_acks_without_double_recording
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)
    msg = update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key")

    assert_equal [YjsFixtures::TwoDocsMerged::DOC1_UPDATE], store
    # The retry is not re-RECORDED, but it IS re-broadcast: if the original
    # attempt recorded and then crashed before distributing, the retry is the
    # only mechanism that can still reach live subscribers. Idempotent apply
    # makes the duplicate broadcast free.
    assert_equal 2, broadcasts.length
    assert_equal [5, 5], acks_in(transmits)
  end

  def test_lost_ack_delete_retry_acks_without_double_recording
    # A pure-delete retry the server already integrated must be acked and not
    # re-recorded (it IS re-broadcast — see the retry test above). Insert
    # content, delete a char, then replay the deletion.
    content = YjsFixtures::DeleteRetry::CONTENT
    deletion = YjsFixtures::DeleteRetry::DELETION

    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(content, id: 1), "doc-key")
    helper.sync_receive(update_message(deletion, id: 2), "doc-key")
    helper.sync_receive(update_message(deletion, id: 3), "doc-key") # lost-ack retry

    assert_equal 2, store.length, "the deletion records once; its retry does not"
    assert_equal 3, broadcasts.length, "the retry re-broadcasts (crash-window heal)"
    assert_equal [1, 2, 3], acks_in(transmits), "every frame is still acked"
  end

  def test_cross_client_origin_gap_is_recorded_once_and_heals
    # DELTA's origins reference client 3's blocks (CONTENT), which this store
    # never saw, so DELTA parks as pending. Its per-client clock lower bound
    # passes, so a clock-only check can't spot it, and the advances? probe
    # misreads the parked update as an already-applied retry — which is why the
    # dedup check is update_adds_content?, not update_advances?. It must be
    # recorded (once), acked, and heal when CONTENT lands.
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::DELTA, id: 7), "doc-key")

    assert_equal [YjsFixtures::CrossClientOrigin::DELTA], store,
                 "the parked delta is recorded, not dropped"
    assert_equal 1, broadcasts.length
    assert_equal [7], acks_in(transmits)

    # The missing content arrives, then the sender retransmits the delta.
    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::CONTENT, id: 8), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::DELTA, id: 9), "doc-key")

    assert_equal 2, store.length, "the healed delta is not recorded a second time"
    assert_equal [7, 8, 9], acks_in(transmits)

    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }

    refute_predicate replay, :pending?, "the gap healed"
  end

  # -- Accepting causal gaps ----------------------------------------------
  #
  # A causally-incomplete update is recorded and acked like any other; it parks
  # as a pending struct and integrates when its dependency arrives. These tests
  # rely on the loader being lossless (doc_state uses encode_state_as_update,
  # which keeps pending) — the store contract this requires.

  # A store that dedups by content hash, standing in for a durable ingress log.
  class HashDedupStore
    def initialize = @log = Hash.new { |h, k| h[k] = {} }
    def append(key, update) = @log[key][Digest::SHA256.hexdigest(update)] ||= update
    def count(key) = @log[key].size

    def load(key)
      updates = @log[key].values
      return nil if updates.empty?

      doc = Y::Doc.new
      updates.each { |u| doc.apply_update(u) }
      doc.encode_state_as_update # lossless: keeps pending
    end
  end

  def test_gap_heals_when_the_dependency_arrives
    store = []
    helper = helper_for(store: store)

    # The gap arrives first, its dependencies after.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U2), "doc-key")

    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }

    refute_predicate replay, :pending?, "the parked struct integrated"
    assert_equal "ABC", replay.read_text("content"), "and its content is present"
  end

  def test_serves_gap_free_state_while_a_gap_is_open
    transmits = []
    helper = helper_for(transmits: transmits)
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    transmits.clear

    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")
    client.handle_sync_message(Base64.strict_decode64(transmits.first["update"]))

    refute_predicate client, :pending?,
                     "a peer is never served content it can't integrate"
  end

  def test_sync_step1_solicits_repair_while_a_gap_is_open
    transmits = []
    gaps = []
    helper = helper_for(transmits: transmits)
    helper.class.on_gap { |key| gaps << key }
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    transmits.clear
    gaps.clear

    # A client syncs. The server serves integrated state AND, because a gap is
    # open, sends its own SyncStep1 to ask this client for the missing dep.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    assert_equal 2, transmits.length, "the reply, plus a SyncStep1 soliciting repair"
    assert_equal ["doc-key"], gaps, "and the open gap is surfaced"
  end

  def test_join_surfaces_an_open_gap
    gaps = []
    helper = helper_for
    helper.class.on_gap { |key| gaps << key }
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    gaps.clear

    helper.sync_subscribed("doc-key")

    assert_equal ["doc-key"], gaps, "a join over an open gap reports it"
  end

  def test_a_content_hash_store_records_a_retransmit_once
    store = HashDedupStore.new
    transmits = []
    helper = helper_for(transmits: transmits)
    helper.class.on_load { |k| store.load(k) }
    helper.class.on_change { |k, u| store.append(k, u) }
    msg = update_message(YjsFixtures::CausalChain::U3, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key") # lost-ack retry

    assert_equal 1, store.count("doc-key")
    assert_equal [5, 5], acks_in(transmits), "both are acked; the CRDT apply is idempotent"
  end

  def test_a_second_distinct_gap_is_recorded_not_read_as_a_duplicate
    # update_advances? flips only on the FIRST pending struct, so a second gap
    # on an already-pending doc reads as a duplicate to it. The dedup check must
    # be update_adds_content?, or this content is silently dropped.
    store = []
    helper = helper_for(store: store)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::DELTA), "doc-key")

    assert_equal 2, store.length, "both gaps are held, not collapsed into one"
  end

  def test_receive_without_a_key_fails_closed
    helper = helper_for

    # No sync_subscribed, no key argument: recording under a nil key and acking
    # would silently misfile the update, so the frame must raise instead.
    error = assert_raises(Y::Error) do
      helper.sync_receive(update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 1))
    end

    assert_match(/document key/, error.message)
    assert_empty acks_in(helper.transmits)
  end

  # -- Store-backed concurrency -------------------------------------------
  #
  # Real MRI threads contend on one document key. Delivery is at-least-once, so a
  # recorder may run concurrently and record a duplicate; what must hold is that
  # the recorded log always converges. The recorder owns its own concurrency (a
  # thread-safe append).
  def appending_recorder(store)
    guard = Mutex.new
    ->(_key, update) { guard.synchronize { store << update } }
  end

  def test_concurrent_duplicate_retries_converge
    key = "store-retry-#{object_id}"
    store = []
    recorder = appending_recorder(store)
    msg = update_message(YjsFixtures::ConcurrentClients::FIVE.first)

    threads = 32.times.map { Thread.new { helper_for(store: store, recorder: recorder).sync_receive(msg, key) } }
    threads.each(&:join)

    refute_empty store, "at-least-once: the update is recorded"

    rebuilt = Y::Doc.new
    store.each { |u| rebuilt.apply_update(u) }
    expected = Y::Doc.new
    expected.apply_update(YjsFixtures::ConcurrentClients::FIVE.first)

    assert_equal expected.encode_state_vector, rebuilt.encode_state_vector,
                 "the recorded log converges, however many duplicate entries it holds"
  end

  def test_concurrent_distinct_and_duplicate_receives_converge
    key = "store-mix-#{object_id}"
    store = []
    recorder = appending_recorder(store)
    five = YjsFixtures::ConcurrentClients::FIVE

    # 5 distinct updates, each delivered by 5 threads (25 total) -> 20 retries.
    25.times.map do |i|
      msg = update_message(five[i % five.length])
      Thread.new { helper_for(store: store, recorder: recorder).sync_receive(msg, key) }
    end.each(&:join)

    rebuilt = Y::Doc.new
    store.each { |u| rebuilt.apply_update(u) }
    expected = Y::Doc.new
    five.each { |u| expected.apply_update(u) }

    assert_equal expected.encode_state_vector, rebuilt.encode_state_vector,
                 "the recorded log converges to all five clients under concurrency"
  end
end
