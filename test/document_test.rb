# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"

# Y::Document owns the storage design: state is the merged snapshot, the
# update rows are only the uncompacted tail, and compaction moves one into the
# other. Exercised against a real database, exactly as the generated channel
# uses it (load_state/append by key) and as bound models use it (.for).
class DocumentTest < Minitest::Test
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  class Page < ActiveRecord::Base
    self.table_name = "pages"
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    Page.delete_all
    # Check the policy on every append, so tests see compaction where they
    # expect it.
    Y::Document.check_compaction_every = 1
  end

  # Some tests change the policy. Put it back so later test files see the
  # defaults.
  def teardown
    Y::Document.compact_every = 256
    Y::Document.check_compaction_every = 16
    Y::Document.compact_min_log_bytes = 4096
    Y::Document.compact_log_ratio = 0.1
  end

  def read_back(key, text: "content")
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state(key))
    doc.read_text(text)
  end

  # -- append / load ---------------------------------------------------------

  def test_append_creates_the_document_and_load_state_round_trips
    Y::Document.append("room-1", CLIENT_ONE)
    Y::Document.append("room-1", CLIENT_TWO)

    assert_equal 1, Y::Document.count
    assert_equal "from doc1from doc2", read_back("room-1")
  end

  def test_merge_is_order_independent
    Y::Document.append("a", CLIENT_ONE)
    Y::Document.append("a", CLIENT_TWO)
    Y::Document.append("b", CLIENT_TWO)
    Y::Document.append("b", CLIENT_ONE)

    assert_equal read_back("a"), read_back("b")
  end

  def test_load_state_is_nil_for_an_unknown_key
    assert_nil Y::Document.load_state("nope")
  end

  def test_load_state_returns_the_snapshot_verbatim_when_the_tail_is_empty
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)
    document.compact!

    assert_equal 0, document.updates.count
    assert_equal document.reload.state, document.load_state, "no rebuild on the fast path"
  end

  def test_load_state_survives_a_compaction_between_the_state_and_tail_reads
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)
    # A reader loads the row (snapshot still nil), then a compaction commits
    # before the reader assembles. The old state-then-tail read order paired
    # the stale in-memory snapshot with the now-empty tail and served
    # nothing; tail-then-fresh-snapshot cannot omit a committed change.
    reader = Y::Document.locate("room-1")
    Y::Document.locate("room-1").compact!

    doc = Y::Doc.new
    doc.apply_update(reader.load_state)

    assert_equal "from doc1", doc.read_text("content")
  end

  def test_documents_are_scoped_by_key
    Y::Document.append("a", CLIENT_ONE)
    Y::Document.append("b", CLIENT_TWO)

    assert_equal "from doc1", read_back("a")
  end

  def test_redelivered_duplicate_delta_is_a_no_op_in_merged_state
    Y::Document.append("room-1", CLIENT_ONE)
    Y::Document.append("room-1", CLIENT_ONE)

    assert_equal "from doc1", read_back("room-1")
  end

  def test_destroying_a_document_sweeps_its_tail
    Y::Document.append("room-1", CLIENT_ONE)

    Y::Document.locate("room-1").destroy!

    assert_equal 0, Y::DocumentUpdate.count
  end

  # -- compacting ---------------------------------------------------------------

  def test_compact_absorbs_the_tail_into_state_and_content_is_identical
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)
    document.append(CLIENT_TWO)
    before = read_back("room-1")

    document.compact!

    assert_equal 0, document.updates.count, "tail deleted"
    assert_predicate document.reload.state, :present?, "state absorbed the tail"
    assert_equal before, read_back("room-1")
  end

  def test_append_compacts_at_or_over_the_threshold
    Y::Document.compact_every = 2
    document = Y::Document.locate!("room-1")

    document.append(CLIENT_ONE)

    assert_equal 1, document.updates.count, "below threshold: no compact"

    document.append(CLIENT_TWO)

    assert_equal 0, document.updates.count, "threshold append compacts"
    assert_equal "from doc1from doc2", read_back("room-1")
  end

  def test_a_jumped_threshold_still_compacts
    Y::Document.compact_every = 2
    document = Y::Document.locate!("room-1")
    # Simulate concurrent appends jumping past the multiple: three rows land
    # before any compaction runs.
    3.times { document.updates.create!(payload: CLIENT_ONE) }

    document.append(CLIENT_TWO)

    assert_equal 0, document.updates.count, "at-or-over fires past the multiple"
  end

  def test_append_compacts_once_the_tail_reaches_a_share_of_the_snapshot
    Y::Document.compact_min_log_bytes = 0
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)

    assert_equal 0, document.updates.count, "no snapshot yet: any tail is due"
    snapshot = document.reload.state.bytesize
    Y::Document.compact_log_ratio = (CLIENT_TWO.bytesize + 1).fdiv(snapshot)

    document.append(CLIENT_TWO)

    assert_equal 1, document.updates.count, "below the ratio: no compact"

    document.append(CLIENT_TWO)

    assert_equal 0, document.updates.count, "at the ratio: compacts"
    assert_equal "from doc1from doc2", read_back("room-1")
  end

  def test_the_compaction_check_runs_on_one_append_in_check_compaction_every
    Y::Document.compact_every = 1
    Y::Document.check_compaction_every = 4
    document = Y::Document.locate!("room-1")
    8.times { document.append(CLIENT_ONE) }

    assert_predicate document.reload.state, :present?, "a checked append compacted"
    assert_operator document.updates.count, :<, 4, "only rows since the last checked one remain"

    Y::Document.check_compaction_every = 1_000_000
    other = Y::Document.locate!("room-2")
    3.times { other.append(CLIENT_ONE) }

    assert_nil other.reload.state, "unchecked appends don't compact"
  end

  def test_load_parts_is_the_snapshot_then_the_tail
    Y::Document.compact_every = 1
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)
    Y::Document.compact_every = nil
    document.append(CLIENT_TWO)
    snapshot, *tail = Y::Document.load_parts("room-1")

    assert_equal document.reload.state, snapshot
    assert_equal [CLIENT_TWO], tail
    doc = Y::Doc.new
    Y::Document.load_parts("room-1").each { |u| doc.apply_update(u) }

    assert_equal read_back("room-1"), doc.read_text("content")
  end

  # -- causal gaps -----------------------------------------------------------

  # -- the sync handshake from the stored rows -------------------------------

  # Edits to one text, each as the update it produced: "abc", then "d", "e",
  # and a delete of the "a" (which moves no state vector).
  def edits
    @edits ||= build_edits
  end

  def build_edits
    source = Y::Doc.new
    text = source.get_text("content")
    [-> { text.insert(0, "abc") }, -> { text.insert(3, "d") }, -> { text.insert(4, "e") },
     -> { text.delete(0, 1) }].map do |edit|
      sv = source.encode_state_vector
      edit.call
      source.encode_state_as_update(sv)
    end
  end

  def apply_all(updates, doc = Y::Doc.new)
    Array(updates).each { |u| doc.apply_update(u) }
    doc
  end

  def test_compaction_stores_the_snapshots_state_vector
    edits.each { |u| Y::Document.append("sv", u) }
    Y::Document.find_by(key: "sv").compact!
    row = Y::Document.find_by(key: "sv")

    assert_equal Y.state_vector_of(row.state), row.state_vector
    assert_equal apply_all(edits).encode_state_vector, row.state_vector
  end

  def test_sync_state_is_the_snapshot_extended_by_the_tail
    abc, d, e, delete = edits
    Y::Document.append("sv", abc)
    Y::Document.find_by(key: "sv").compact!
    [e, d, delete].each { |u| Y::Document.append("sv", u) }

    assert_equal apply_all(edits).encode_state_vector, Y::Document.sync_state("sv")
  end

  def test_sync_diff_brings_any_client_up_to_date
    abc, d, e, delete = edits
    [abc, delete].each { |u| Y::Document.append("sv", u) }
    Y::Document.find_by(key: "sv").compact!
    [d, e].each { |u| Y::Document.append("sv", u) }

    [[], [abc], [abc, d], [abc, d, e]].each do |held|
      client = apply_all(held)

      apply_all(Y::Document.sync_diff("sv", client.encode_state_vector), client)

      assert_equal "bcde", client.read_text("content"),
                   "a client holding #{held.size} edits gets the rest, the snapshot's delete included"
    end
  end

  def test_sync_diff_sends_the_snapshot_as_stored_to_a_client_with_nothing
    edits.each { |u| Y::Document.append("sv", u) }
    Y::Document.find_by(key: "sv").compact!

    assert_equal [Y::Document.find_by(key: "sv").state], Y::Document.sync_diff("sv", "\x00".b)
  end

  def test_sync_diff_for_a_client_missing_nothing_is_one_empty_update
    Y::Document.append("sv", edits.first)
    Y::Document.find_by(key: "sv").compact!
    Y::Document.create!(key: "empty")

    assert_equal [Y::Document::EMPTY_UPDATE], Y::Document.sync_diff("sv", apply_all(edits.first).encode_state_vector)
    assert_equal [Y::Document::EMPTY_UPDATE], Y::Document.sync_diff("empty", "\x00".b)
  end

  # A gap in storage doesn't change the handshake: the client gets what is
  # stored, gap included, and heals when the missing update arrives, as
  # with a Y.js server.
  def test_the_handshake_serves_a_stored_gap
    Y::Document.append("gap", YjsFixtures::Gap::DEPENDENT)
    Y::Document.find_by(key: "gap").compact!
    client = Y::Doc.new

    refute_nil Y::Document.sync_state("gap")
    apply_all(Y::Document.sync_diff("gap", "\x00".b), client)
    client.apply_update(YjsFixtures::Gap::FIRST)

    assert_equal "ab", client.read_text("notepad")
    assert_nil Y::Document.sync_state("unknown")
  end

  def test_the_handshake_reads_the_snapshot_without_a_stored_state_vector
    abc, d, e, delete = edits
    [abc, delete].each { |u| Y::Document.append("sv", u) }
    Y::Document.find_by(key: "sv").compact!
    Y::Document.where(key: "sv").update_all(state_vector: nil) # compacted before the column
    [d, e].each { |u| Y::Document.append("sv", u) }
    expected = apply_all(edits).encode_state_vector

    assert_equal expected, Y::Document.sync_state("sv")
    Y::Document.stub(:stores_state_vector?, false) do
      assert_equal expected, Y::Document.sync_state("sv")
    end
  end

  # Compaction folds every row it read, gap or not, by merging bytes: it
  # never asks yrs what integrated.
  def test_compaction_folds_every_row_and_keeps_a_gap_in_state
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_TWO)
    document.append(YjsFixtures::Gap::DEPENDENT)

    document.compact!

    assert_equal 0, document.updates.count
    assert_equal "from doc2", read_back("room-1")
    peer = Y::Doc.new
    peer.apply_update(Y::Document.load_state("room-1"))
    peer.apply_update(YjsFixtures::Gap::FIRST)

    assert_equal "ab", peer.read_text("notepad"), "the gap was kept and heals"
  end

  # yrs doesn't report this gap as pending: the update skips ahead of its
  # client's clock while the structs it attaches to are present. Compaction
  # that kept only what yrs integrated lost it.
  def test_an_update_ahead_of_its_clients_clock_survives_compaction
    source = Y::Doc.new
    text = source.get_text("content")
    text.insert(0, "hello world hello world")
    base = source.encode_state_as_update
    skipped = source.edit { text.insert(5, "AAA") }
    ahead = source.edit { text.insert(20, "BBB") }
    document = Y::Document.locate!("room-1")
    document.append(base)
    document.append(ahead)
    document.compact!
    document.append(skipped)
    document.compact!

    assert_equal 0, document.updates.count
    assert_equal text.to_s, read_back("room-1")
  end

  # Two clients' edits, stored with local disorder (as from concurrent
  # writers) and compacted at random points, end equal to the clients'
  # document. These seeds lost edits when compaction kept only what yrs
  # reported as integrated, and when it judged rows by state vector.
  def test_disordered_updates_with_random_compactions_converge
    Y::Document.check_compaction_every = 1_000_000
    [4, 46, 68].each do |seed|
      Y::DocumentUpdate.delete_all
      Y::Document.delete_all
      rand = Random.new(seed)
      updates, expected = two_client_session(rand)
      document = Y::Document.locate!("room-1")
      updates.each_slice(16).flat_map { |slice| slice.shuffle(random: rand) }.each do |update|
        document.append(update)
        document.compact! if rand.rand < 0.15
      end
      document.compact!

      assert_equal expected, read_back("room-1"), "seed #{seed}"
    end
  end

  # 200 edits from two clients that see most of each other's edits, and
  # the text they end with.
  def two_client_session(rand)
    clients = [Y::Doc.new, Y::Doc.new]
    updates = Array.new(200) do |i|
      doc = clients[i % 2]
      text = doc.get_text("content")
      update = doc.edit do
        if rand.rand < 0.25 && text.length > 3
          text.delete(rand.rand(text.length - 1), 1)
        else
          text.insert(rand.rand(text.length + 1), %w[a bc d e].sample(random: rand))
        end
      end
      clients[(i + 1) % 2].apply_update(update) if rand.rand < 0.8
      update
    end
    [updates, apply_all(updates).read_text("content")]
  end

  def test_load_state_preserves_an_unhealed_gap_so_a_peer_can_heal_it
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)
    document.compact!

    peer = Y::Doc.new
    peer.apply_update(Y::Document.load_state("room-1"))
    peer.apply_update(YjsFixtures::Gap::FIRST)

    assert_equal "ab", peer.read_text("notepad"), "the peer heals without another load"
  end

  def test_a_gap_heals_across_compactions
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)
    document.compact!
    document.append(YjsFixtures::Gap::FIRST)

    assert_equal "ab", read_back("room-1", text: "notepad"), "healed before any compaction"

    document.compact!

    assert_equal 0, document.updates.count
    assert_equal "ab", read_back("room-1", text: "notepad")
  end

  # -- identity: .for, adoption, derivation ----------------------------------

  def test_for_binds_a_record_and_derives_the_key
    page = Page.create!
    document = Y::Document.for(page, :body)

    assert_equal page, document.record
    assert_equal "body", document.name
    # Derived from the polymorphic record_type; namespaces keep their slash.
    assert_equal "document_test/page/#{page.id}/body", document.key
  end

  def test_for_converges_on_one_row_per_record_and_name
    page = Page.create!

    document = Y::Document.for(page, :body)

    assert_equal document, Y::Document.for(page, :body)
    refute_equal document, Y::Document.for(page, :summary), "each attribute gets its own document"
    refute_equal document, Y::Document.for(Page.create!, :body), "each record gets its own document"
  end

  def test_for_adopts_a_key_only_row_bearing_the_derived_key
    page = Page.create!
    # A channel appended under the key .for will derive, before any binding
    # existed: the two identities must converge, not collide.
    Y::Document.append("document_test/page/#{page.id}/body", CLIENT_ONE)

    document = Y::Document.for(page, :body)

    assert_equal page, document.record
    assert_equal "body", document.name
    assert_equal 1, Y::Document.count, "adopted, not duplicated"
    assert_equal "from doc1", read_back(document.key), "the orphan's content survives adoption"
  end

  def test_for_retries_past_a_channel_creating_the_key_only_row_mid_call
    page = Page.create!
    key = "document_test/page/#{page.id}/body"
    original = Y::Document.method(:adopt)
    raced = false
    racing_adopt = lambda do |record, name|
      if raced
        original.call(record, name)
      else
        # The channel wins the race after adopt looked and before the
        # bound insert lands: the insert collides on the key index and
        # create_or_find_by!'s record+name retry misses the key-only row.
        raced = true
        Y::Document.create!(key: key)
        nil
      end
    end

    document = Y::Document.stub(:adopt, racing_adopt) { Y::Document.for(page, :body) }

    assert_equal page, document.record
    assert_equal 1, Y::Document.count, "adopted on the retry, not duplicated"
  end

  def test_a_supplied_key_is_never_overwritten
    page = Page.create!
    document = Y::Document.create!(record: page, name: "body", key: "custom")

    assert_equal "custom", document.key
  end

  def test_key_only_documents_must_supply_a_key
    assert_raises(ActiveRecord::RecordInvalid) { Y::Document.create! }
  end

  def test_half_bound_shapes_are_invalid
    page = Page.create!

    assert_raises(ActiveRecord::RecordInvalid) { Y::Document.create!(key: "k1", record: page) }
    assert_raises(ActiveRecord::RecordInvalid) { Y::Document.create!(key: "k2", name: "body") }
    assert_raises(ActiveRecord::RecordInvalid) { Y::Document.create!(key: "k3", record_id: page.id) }
  end

  def test_an_unsaved_record_cannot_derive_a_key
    assert_raises(ActiveRecord::RecordInvalid) { Y::Document.create!(record: Page.new, name: "body") }
  end

  def test_locate_and_locate_bang
    assert_nil Y::Document.locate("room-1")

    created = Y::Document.locate!("room-1")

    assert_equal created, Y::Document.locate("room-1")
    assert_equal created, Y::Document.locate!("room-1")
  end
end
