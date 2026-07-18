# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "base64"

# Y::Sync::Engine on its own, with no transport. Y::ActionCable::Sync is one
# adapter over it (see sync_test.rb); these pin the protocol core directly, so
# a second adapter (a REST + pub/sub binding, say) inherits the same
# guarantees. Every update here is a real Yjs delta captured from Y.js, since
# a Doc is read-only from Ruby — the client produces updates, the engine
# relays/records/reads them opaquely.
class SyncEngineTest < Minitest::Test
  HELLO = YjsFixtures::TextHelloWorld::UPDATE  # "hello world" on "content"
  DOC1 = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  DOC2 = YjsFixtures::TwoDocsMerged::DOC2_UPDATE
  CHAIN = YjsFixtures::CausalChain             # U1/U2/U3 -> A/B/C; U2 depends on U1
  PRESENCE = YjsFixtures::Presence::FRAME

  # An append-log store, like the ActionCable tests use. `load` merges it.
  def build_engine(store: [], recorder: nil)
    recorder ||= ->(_key, update) { store << update }
    loader = ->(_key) { merged(store) }
    [Y::Sync::Engine.new(load: loader, change: recorder), store]
  end

  def merged(updates)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each { |u| doc.apply_update(u) }
    doc.encode_state_as_update
  end

  def frame(update) = Y.wrap_update(update)

  def handle(engine, update)
    f = frame(update)
    engine.handle("doc", Base64.strict_encode64(f), f)
  end

  # --- recording + relay ---

  def test_a_new_update_is_recorded_and_relayed
    engine, store = build_engine
    result = handle(engine, HELLO)

    assert_equal :recorded, result.ack
    assert_predicate result, :ack?, "a recorded update is acked"
    refute_nil result.broadcast, "and relayed to peers"
    assert_nil result.reply, "with no direct reply"
    assert_equal [HELLO], store, "the delta was appended to the store"
  end

  def test_change_records_before_relay
    order = []
    recorder = ->(_key, _update) { order << :recorded }
    engine, = build_engine(recorder: recorder)

    result = handle(engine, HELLO)
    order << :relayed if result.broadcast

    assert_equal %i[recorded relayed], order, "record precedes relay"
  end

  def test_a_raising_recorder_rejects_the_update
    engine, = build_engine(recorder: ->(_k, _u) { raise "store down" })

    assert_raises(RuntimeError) { handle(engine, HELLO) }
  end

  # --- reliable delivery ---

  def test_a_lost_ack_retry_is_relayed_but_not_re_recorded
    store = [HELLO]
    engine, = build_engine(store: store)

    result = handle(engine, HELLO) # same update again

    assert_equal :applied, result.ack
    assert_predicate result, :ack?, "a retry is still acked"
    refute_nil result.broadcast, "and re-relayed (the first relay may have been lost)"
    assert_equal [HELLO], store, "but not recorded twice"
  end

  # --- causal gaps ---

  def test_a_gappy_update_is_rejected_with_a_resync
    engine, store = build_engine

    result = handle(engine, CHAIN::U2) # depends on U1, which the store lacks

    assert_equal :gap, result.ack
    refute_predicate result, :ack?, "a gap is not acked"
    assert_nil result.broadcast, "and not relayed"
    refute_nil result.reply, "the reply is a resync request (server SyncStep1)"
    assert_equal Y::Sync::Engine::MSG_KIND_SYNC_STEP1, Y.message_kind(result.reply)
    assert_empty store, "nothing recorded"
  end

  def test_a_complete_delta_after_a_gap_records_and_recovers
    engine, = build_engine

    handle(engine, CHAIN::U2) # gap
    complete = merged([CHAIN::U1, CHAIN::U2]) # what the resync would resend
    result = handle(engine, complete)

    assert_equal :recorded, result.ack
    assert_equal "AB", Y::Doc.new.tap { |d| d.apply_update(engine.full_state("doc")) }.read_text("content")
  end

  # --- sync handshake ---

  def test_sync_step1_frame_answers_from_the_store
    engine, = build_engine(store: [DOC1])

    frame = engine.sync_step1("doc")

    assert_equal Y::Sync::Engine::MSG_KIND_SYNC_STEP1, Y.message_kind(frame)
  end

  def test_incoming_sync_step1_gets_a_reply_not_a_broadcast
    engine, = build_engine(store: [DOC1])

    # A client's SyncStep1 (its empty state vector) — answered with a SyncStep2.
    step1 = Y::Doc.new.sync_step1
    result = engine.handle("doc", Base64.strict_encode64(step1), step1)

    refute_nil result.reply, "answered with the client's missing updates"
    assert_nil result.broadcast, "not relayed to peers"
    assert_equal :noop, result.ack, "a handshake is not an ack-able update"
  end

  def test_full_state_is_gap_free
    engine, = build_engine(store: [DOC1, DOC2])

    doc = Y::Doc.new
    doc.apply_update(engine.full_state("doc"))

    assert_equal "from doc1from doc2", doc.read_text("content")
  end

  # --- awareness ---

  def test_awareness_relays_without_recording
    engine, store = build_engine

    result = engine.handle("doc", Base64.strict_encode64(PRESENCE), PRESENCE)

    refute_nil result.broadcast, "presence is relayed"
    assert_equal :noop, result.ack, "and never acked"
    assert_empty store, "and never recorded"
  end

  # --- junk ---

  def test_an_unclassifiable_frame_is_a_noop
    engine, store = build_engine
    junk = "not a protocol frame"

    result = engine.handle("doc", Base64.strict_encode64(junk), junk)

    assert_nil result.reply
    assert_nil result.broadcast
    assert_equal :noop, result.ack
    assert_empty store
  end
end
