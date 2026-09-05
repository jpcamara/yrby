# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "y/action_cable"
require "logger"
require "stringio"
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

  def helper_for(store: [], recorder: nil, transmits: [], broadcasts: [], authorized: true)
    test = self
    recorder ||= ->(_key, update) { store << update }
    loader = ->(_key) { test.doc_state(store) }
    klass = Class.new do
      include Y::ActionCable::Sync

      attr_accessor :transmits, :broadcasts, :streams, :logger, :rejected

      def transmit(data) = transmits << data

      def reject = self.rejected = true

      def stream_from(name, **opts, &)
        streams << [name, opts, !block_given?]
      end

      define_method(:sync_distribute) { |encoded| broadcasts << encoded }
    end
    # Most tests exercise the sync protocol, not authorization; opting the
    # helper in keeps them on the happy path. authorized: false leaves the
    # concern's fail-closed default in place.
    klass.define_method(:authorized?) { |_key| true } if authorized
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

  def test_sync_requires_loader_and_recorder_without_the_rails_default
    no_loader = Class.new do
      include Y::ActionCable::Sync

      on_change { |_key, _update| nil }
    end
    no_recorder = Class.new do
      include Y::ActionCable::Sync

      on_load { |_key| nil }
    end

    # Outside a yrby-rails app there is no Y::Document default, and the
    # concern fails closed. Stubbed by hand (no minitest/mock in this suite)
    # rather than relied on, because the full suite loads the models into
    # this process.
    sync = Y::ActionCable::Sync
    sync.singleton_class.alias_method(:real_default_hook, :default_hook)
    sync.define_singleton_method(:default_hook) { |_name| nil }
    begin
      assert_match(/on_load/, assert_raises(Y::Error) { no_loader.new.sync_subscribed("doc") }.message)
      assert_match(/on_change/, assert_raises(Y::Error) { no_recorder.new.sync_subscribed("doc") }.message)
    ensure
      sync.singleton_class.alias_method(:default_hook, :real_default_hook)
      sync.singleton_class.remove_method(:real_default_hook)
    end
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

  def test_subscription_is_refused_until_the_channel_defines_authorized
    helper = helper_for(authorized: false)

    refute helper.sync_subscribed("doc")
    assert helper.rejected, "the default authorized? must reject"
    assert_empty helper.streams, "no stream may open before authorization"
    assert_empty helper.transmits, "no state may be served before authorization"
  end

  def test_the_default_rejection_says_how_to_fix_it
    log = StringIO.new
    helper = helper_for(authorized: false)
    helper.logger = Logger.new(log)

    helper.sync_subscribed("doc")

    assert_match(/authorized\?/, log.string)
    assert_match(/public documents/, log.string)
  end

  def test_a_channel_authorized_override_gets_the_key_and_can_refuse
    seen = nil
    helper = helper_for
    helper.define_singleton_method(:authorized?) do |key|
      seen = key
      false
    end
    log = StringIO.new
    helper.logger = Logger.new(log)

    refute helper.sync_subscribed("doc-7")

    assert_equal "doc-7", seen
    assert helper.rejected
    # An app that decided "no" needs no lecture about defining authorized?.
    refute_match(/define authorized\?/, log.string)
  end

  def test_an_authorized_subscription_proceeds
    helper = helper_for
    helper.define_singleton_method(:authorized?) { |_key| true }
    helper.sync_subscribed("doc")

    refute helper.rejected
    assert_equal 1, helper.transmits.length, "the opening handshake went out"
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

  def test_sync_step1_is_answered_with_full_state_including_pending
    # A store holding a gappy update: the loaded doc has a pending struct.
    # The concern serves full state, pending included, like any Yjs server;
    # the client parks the pending struct the same way and heals it when the
    # missing dependency arrives.
    transmits = []
    helper = helper_for(store: [YjsFixtures::Gap::DEPENDENT], transmits: transmits)

    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    assert_equal 1, transmits.length, "the SyncStep2 reply"
    reply = Base64.strict_decode64(transmits.first["update"])
    client.handle_sync_message(reply)

    assert_predicate client, :pending?, "the pending struct was served and parked"
    client.apply_update(YjsFixtures::Gap::FIRST)

    refute_predicate client, :pending?, "and healed once the dependency arrived"
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

    # The write path records without rebuilding, so on_load runs when state
    # is served: a SyncStep1 rebuilds via sync_load_doc, proving the loader
    # runs in the channel's context.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

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

  def test_lost_ack_retry_re_records_re_relays_and_re_acks
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, transmits: transmits, broadcasts: broadcasts)
    msg = update_message(YjsFixtures::TwoDocsMerged::DOC1_UPDATE, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key")

    # The write path records without rebuilding, so a lost-ack retry records
    # again; replaying the log converges anyway, because applying a CRDT
    # update twice is a no-op. The re-broadcast also closes the crash window
    # between the original record and its relay.
    assert_equal [YjsFixtures::TwoDocsMerged::DOC1_UPDATE] * 2, store
    assert_equal 2, broadcasts.length
    assert_equal [5, 5], acks_in(transmits)
    replay = Y::Doc.new
    store.each { |u| replay.apply_update(u) }

    assert_equal "from doc1", replay.read_text("content"), "duplicate records replay to the same document"
  end

  # -- causal gaps ---------------------------------------------------------
  #
  # A causally-incomplete update is recorded and acked like any other
  # (ack-on-durable) and served onward like any other state; it stays pending
  # until its dependency arrives; join and reconnect handshakes heal it.
  # These tests rely on the loader being lossless (doc_state uses
  # encode_state_as_update, which keeps pending); the store contract this
  # behavior requires.

  # A store that dedups by content hash: an option for apps that want the
  # ingress log deduplicated, since the write path doesn't rebuild the doc to
  # dedup a retry.
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

  def test_records_relays_and_acks_a_gapped_update
    store = []
    broadcasts = []
    transmits = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u },
                        transmits: transmits, broadcasts: broadcasts)

    # U3 depends on U2 -> U1, neither of which the store has: a genuine gap.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert_equal [YjsFixtures::CausalChain::U3], store, "the gapped update is recorded"
    assert_equal 1, broadcasts.length, "and relayed to peers (they park it as pending too)"
    assert_equal [1], acks_in(transmits), "and acked immediately (ack-on-durable)"
    refute(transmits.any? { |t| t.is_a?(Hash) && t.key?("update") }, "no SyncStep1 resync was sent")
  end

  def test_gap_heals_when_the_dependency_arrives
    store = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u })

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

  def test_a_joiner_receives_the_open_gap_and_heals_with_the_room
    store = []
    transmits = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    transmits.clear

    # A joining client receives full state, the pending U3 included: it parks
    # it exactly as the server did.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    reply = Base64.strict_decode64(transmits.first["update"])
    client.handle_sync_message(reply)

    assert_predicate client, :pending?, "the open gap traveled to the joiner"

    # The missing dependencies arrive (their sender retransmits until acked);
    # the server relays them, and the joiner's copy heals in place.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U1, id: 2), "doc-key")
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U2, id: 3), "doc-key")
    client.apply_update(YjsFixtures::CausalChain::U1)
    client.apply_update(YjsFixtures::CausalChain::U2)

    refute_predicate client, :pending?, "the joiner healed with the room"
    assert_equal "ABC", client.read_text("content"), "into the complete document"
  end

  def test_a_deduping_store_collapses_retries
    # The write path doesn't rebuild the doc, so a store that wants a deduped
    # ingress log does it itself (content hash); the concern doesn't care.
    store = HashDedupStore.new
    broadcasts = []
    transmits = []
    helper = helper_for(transmits: transmits, broadcasts: broadcasts)
    helper.class.on_load { |k| store.load(k) }
    helper.class.on_change { |k, u| store.append(k, u) }
    msg = update_message(YjsFixtures::CausalChain::U3, id: 5)

    helper.sync_receive(msg, "doc-key")
    helper.sync_receive(msg, "doc-key") # lost-ack retry

    assert_equal 1, store.count("doc-key"), "the store deduped the retry by content hash"
    assert_equal [5, 5], acks_in(transmits), "both are acked (ack-on-durable, idempotent)"
  end

  def test_serving_while_a_gap_is_open_sends_no_extra_frames
    gaps = []
    store = []
    transmits = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)
    helper.class.on_gap { |key| gaps << key }
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3), "doc-key") # open a gap
    transmits.clear

    # A client sends SyncStep1. The server answers it and surfaces the gap
    # through on_gap; nothing else is transmitted. Healing rides the ack loop
    # and the join/reconnect handshakes.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    assert_equal 1, transmits.length, "the SyncStep2 reply is the only frame"
    assert_equal ["doc-key"], gaps, "on_gap fired for the open gap"
  end

  def test_observes_an_open_gap_at_serve_time
    logged = []
    gaps = []
    store = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u })
    helper.logger = capturing_logger(logged)
    helper.class.on_gap { |key| gaps << key }

    # The write path records without observing: the gap is durable, quiet.
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")

    assert_empty gaps, "recording a gap does not observe it"

    # Serving rebuilds the doc; an open gap surfaces there.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    assert(logged.any? { |lvl, msg| lvl == :info && msg.include?("causal gap") && msg.include?("doc-key") },
           "the open gap is logged at info so it is findable")
    assert_equal ["doc-key"], gaps, "the on_gap hook fired with the document key"
  end

  def test_on_gap_hook_errors_do_not_break_frame_handling
    logged = []
    store = []
    transmits = []
    helper = helper_for(store: store, recorder: ->(_k, u) { store << u }, transmits: transmits)
    helper.logger = capturing_logger(logged)
    helper.class.on_gap { |_key| raise "metrics backend down" }
    helper.sync_receive(update_message(YjsFixtures::CausalChain::U3, id: 1), "doc-key")
    transmits.clear

    # Serving observes the open gap; the raising hook must not break the serve.
    client = Y::Doc.new
    helper.sync_receive({ "update" => Base64.strict_encode64(client.sync_step1) }, "doc-key")

    refute_empty transmits, "the handshake was still answered"
    assert_equal [YjsFixtures::CausalChain::U3], store, "the gap stayed recorded"
    assert(logged.any? { |lvl, msg| lvl == :error && msg.include?("on_gap hook raised") })
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
