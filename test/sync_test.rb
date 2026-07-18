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

    assert_equal 1, transmits.length
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

  def test_rejects_gapped_update_and_requests_resync
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1, id: 1), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 2), "doc-key")

    assert_equal [YjsFixtures::CausalChain::U1], store
    assert_equal 1, broadcasts.length
    assert_equal [1], acks_in(transmits)
    assert_operator transmits.length, :>, 1, "gapped update should trigger a SyncStep1 resync"
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

  def test_cross_client_origin_gap_is_resynced_not_acked
    # DELTA's origins reference client 3's blocks (CONTENT), which this store
    # never saw. Its per-client clock lower bound passes, so a clock-only ready
    # check used to let it through — and the advances? probe then misread the
    # parked update as an already-applied retry: acked :applied and dropped.
    # It must instead be rejected as a gap: resynced, never recorded, never
    # acked.
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::DELTA, id: 7), "doc-key")

    assert_empty store, "a causally-incomplete update is never recorded"
    assert_empty broadcasts
    assert_empty acks_in(transmits), "and never acked (the old bug acked it)"
    assert_equal 1, transmits.length, "a resync (SyncStep1) was requested"

    # Once the missing content arrives, the same delta is ready and records.
    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::CONTENT, id: 8), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CrossClientOrigin::DELTA, id: 9), "doc-key")

    assert_equal 2, store.length, "content + delta both recorded once healed"
    assert_equal [8, 9], acks_in(transmits)
  end

  # -- causal_gap_policy: :accept and :accept_strict ----------------------
  #
  # :accept records + acks a gappy update immediately (ack-on-durable) via an
  # inverted write path that doesn't rebuild the doc; dedup is delegated to the
  # store. :accept_strict records it but withholds the ack until it integrates.
  # Serving stays gap-free under every policy. These tests rely on the loader
  # being lossless (doc_state uses encode_state_as_update, which keeps pending) —
  # the store contract accept modes require.
  def policy_helper(policy, **)
    helper = helper_for(**)
    helper.class.causal_gap_policy policy
    helper
  end

  # A store that dedups by content hash: the durable ingress log :accept mode
  # relies on, since :accept doesn't rebuild the doc to dedup a retry.
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

  def test_causal_gap_policy_defaults_reject_is_settable_validated_and_inherited
    base = Class.new do
      include Y::ActionCable::Sync

      on_load { |_k| nil }
      on_change { |_k, _u| nil }
    end

    assert_equal :reject, base.causal_gap_policy, "defaults to :reject"
    base.causal_gap_policy :accept

    assert_equal :accept, base.causal_gap_policy
    assert_equal :accept, Class.new(base).causal_gap_policy, "subclasses inherit the setting"
    assert_raises(ArgumentError) { base.causal_gap_policy :nonsense }
  end

  def test_accept_records_relays_and_acks_a_gapped_update
    store = []
    broadcasts = []
    transmits = []
    helper = policy_helper(:accept, store: store, recorder: ->(_k, u) { store << u },
                                    transmits: transmits, broadcasts: broadcasts)

    # U3 depends on U2 -> U1, neither of which the store has: a genuine gap.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert_equal [YjsFixtures::CausalChain::U3], store, "the gapped update is recorded, not rejected"
    assert_equal 1, broadcasts.length, "and relayed to peers (they park it as pending too)"
    assert_equal [1], acks_in(transmits), "and acked immediately (ack-on-durable)"
    refute(transmits.any? { |t| t.is_a?(Hash) && t.key?("update") }, "no SyncStep1 resync was sent")
  end

  def test_accept_gap_heals_when_the_dependency_arrives
    store = []
    helper = policy_helper(:accept, store: store, recorder: ->(_k, u) { store << u })

    # Arrive fully out of causal order: C, then B, then A.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U2), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1), "doc-key")

    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }
    expected = Y::Doc.new
    [YjsFixtures::CausalChain::U1, YjsFixtures::CausalChain::U2,
     YjsFixtures::CausalChain::U3].each { |u| expected.apply_update(u) }

    refute_predicate replay, :pending?, "nothing is left pending once all dependencies arrived"
    assert_equal "ABC", replay.read_text("content"),
                 "replaying the out-of-order recorded log heals every gap into the complete document"
    assert_equal expected.encode_state_vector, replay.encode_state_vector,
                 "the healed doc integrated exactly the same structs as an in-order apply"
  end

  def test_accept_serves_gap_free_state_while_a_gap_is_open
    store = []
    transmits = []
    helper = policy_helper(:accept, store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    transmits.clear

    # A joining client asks for state. It must receive integrated-only state —
    # the pending U3 is never served — so it is not left holding a pending struct.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    reply = Base64.strict_decode64(transmits.first["update"])
    client.handle_sync_message(reply)

    refute_predicate client, :pending?, "the open gap was not served to the joining client"
  end

  def test_accept_delegates_dedup_to_the_store
    # :accept doesn't rebuild the doc, so a lost-ack retry is deduped by the
    # store's idempotency (content hash), not the concern.
    store = HashDedupStore.new
    broadcasts = []
    transmits = []
    helper = policy_helper(:accept, transmits: transmits, broadcasts: broadcasts)
    helper.class.on_load { |k| store.load(k) }
    helper.class.on_change { |k, u| store.append(k, u) }
    msg = update_message(YjsFixtures::CausalChain::U3, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key") # lost-ack retry

    assert_equal 1, store.count("doc-key"), "the store deduped the retry by content hash"
    assert_equal [5, 5], acks_in(transmits), "both are acked (ack-on-durable, idempotent)"
  end

  def test_accept_join_solicits_repair_and_fires_on_gap
    gaps = []
    store = []
    transmits = []
    helper = policy_helper(:accept, store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)
    helper.class.on_gap { |key| gaps << key }
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key") # open a gap
    transmits.clear

    # A client sends SyncStep1. The server serves integrated state AND, because a
    # gap is open, sends its own SyncStep1 to solicit the missing dependency.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    kinds = transmits.map { |t| Y.message_kind(Base64.strict_decode64(t["update"])) }

    assert_includes kinds, Y::ActionCable::Sync::MSG_KIND_SYNC_STEP1,
                    "the server solicited a repair (SyncStep1) while the gap was open"
    assert_includes gaps, "doc-key", "on_gap fired for the open gap"
  end

  def test_accept_strict_records_a_gap_but_withholds_the_ack
    store = []
    broadcasts = []
    transmits = []
    helper = policy_helper(:accept_strict, store: store, recorder: ->(_k, u) { store << u },
                                           transmits: transmits, broadcasts: broadcasts)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert_equal [YjsFixtures::CausalChain::U3], store, "the gap is recorded (durable on arrival)"
    assert_equal 1, broadcasts.length, "and relayed"
    assert_empty acks_in(transmits), "but NOT acked until it integrates (self-signaling)"
  end

  def test_accept_strict_acks_once_the_gap_integrates
    store = []
    transmits = []
    helper = policy_helper(:accept_strict, store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key") # gap: recorded, not acked
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U2, id: 2), "doc-key") # still gappy: not acked
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1, id: 3), "doc-key") # heals: ready, acked

    assert_includes acks_in(transmits), 3, "the update that integrates the chain is acked"
    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }

    assert_equal "ABC", replay.read_text("content"), "and the document is whole"
  end

  def test_accept_strict_does_not_double_record_a_pending_retry
    store = []
    broadcasts = []
    transmits = []
    helper = policy_helper(:accept_strict, store: store, recorder: ->(_k, u) { store << u },
                                           transmits: transmits, broadcasts: broadcasts)
    msg = update_message(YjsFixtures::CausalChain::U3, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key") # retry of a still-pending gap

    assert_equal [YjsFixtures::CausalChain::U3], store,
                 "a retry of an already-pending gap is not re-recorded (sync_adds_content?)"
    assert_equal 2, broadcasts.length, "but it is re-broadcast (crash-window heal)"
    assert_empty acks_in(transmits),
                 "and the still-gappy retry is NOT acked — the sender must keep retransmitting"
  end

  def test_accept_strict_does_not_observe_a_gap_when_recording_fails
    # on_change raises (store down) -> the update is rejected. on_gap must NOT
    # fire and no gap must be logged: nothing was persisted, so a metric or log
    # claiming a durable gap would be false, and would re-inflate on every retry.
    logged = []
    gaps = []
    helper = policy_helper(:accept_strict, recorder: ->(_k, _u) { raise "store unavailable" })
    helper.logger = capturing_logger(logged)
    helper.class.on_gap { |key| gaps << key }

    assert_raises(RuntimeError) do
      helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    end

    assert_empty gaps, "on_gap did not fire for a gap that was never persisted"
    refute(logged.any? { |_lvl, msg| msg.include?("causal gap") },
           "no durable-looking gap was logged when the record failed")
  end

  def test_accept_observes_a_gap_via_log_and_hook
    logged = []
    gaps = []
    store = []
    helper = policy_helper(:accept_strict, store: store, recorder: ->(_k, u) { store << u })
    helper.logger = capturing_logger(logged)
    helper.class.on_gap { |key| gaps << key }

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert(logged.any? { |lvl, msg| lvl == :info && msg.include?("causal gap") && msg.include?("doc-key") },
           "a gap is logged at info so it is findable")
    assert_equal ["doc-key"], gaps, "the on_gap hook fired with the document key"
  end

  def test_on_gap_hook_errors_do_not_break_frame_handling
    logged = []
    store = []
    helper = policy_helper(:accept_strict, store: store, recorder: ->(_k, u) { store << u })
    helper.logger = capturing_logger(logged)
    helper.class.on_gap { |_key| raise "metrics backend down" }

    # The gap is still recorded even though the hook raised.
    assert_nil helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    assert_equal [YjsFixtures::CausalChain::U3], store
    assert(logged.any? { |lvl, msg| lvl == :error && msg.include?("on_gap hook raised") })
  end

  def test_reject_mode_default_still_resyncs_a_gap
    store = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits) # default policy

    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert_empty store, "the default rejects a gap rather than recording it"
    assert_empty acks_in(transmits), "and does not ack it"
    assert_equal 1, transmits.length, "a resync (SyncStep1) was requested instead"
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

    32.times.map { Thread.new { helper_for(store: store, recorder: recorder).sync_receive(msg, key) } }
            .each(&:join)

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
