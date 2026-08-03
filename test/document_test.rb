# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"

# Y::Document owns the storage design: state is the merged snapshot, the
# update rows are only the uncompacted tail, and compacting moves one into the
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
    Y::Document.compact_every = 64
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

  def test_append_moves_changed_at_and_compact_does_not
    document = Y::Document.locate!("room-1")
    document.append(CLIENT_ONE)

    assert_predicate document.changed_at, :present?, "append stamps changed_at"

    document.update!(changed_at: 1.hour.ago)
    stamped = document.changed_at

    document.compact!

    assert_equal stamped, document.reload.changed_at,
                 "compacting is not a content change; projections stamped before it stay fresh"
  end

  # -- causal gaps -----------------------------------------------------------

  def test_a_gapped_batch_is_quarantined_not_compacted_and_not_destroyed
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)

    document.compact!

    assert_equal 1, document.updates.where(pending: true).count, "the gap is quarantined"
    assert_nil document.reload.state, "a gap is never compacted into state"
  end

  def test_clean_rows_compact_even_while_a_gap_is_quarantined
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)
    document.compact!
    document.append(CLIENT_TWO)

    document.compact!

    assert_equal [true], document.updates.pluck(:pending),
                 "the clean row compacted; only the gap remains, quarantined"
    assert_equal "from doc2", read_back("room-1")
  end

  def test_quarantined_rows_do_not_count_toward_the_compact_trigger
    Y::Document.compact_every = 2
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)
    document.append(YjsFixtures::Gap::DEPENDENT_OTHER)

    document.append(CLIENT_ONE)

    assert_equal 1, document.updates.where(pending: false).count,
                 "one clean row is below the threshold; quarantined rows don't trigger"
  end

  def test_a_healed_gap_is_served_immediately_and_compacts_clean
    document = Y::Document.locate!("room-1")
    document.append(YjsFixtures::Gap::DEPENDENT)
    document.compact!

    document.append(YjsFixtures::Gap::FIRST)

    assert_equal "ab", read_back("room-1", text: "notepad"), "healed content serves before any compaction"

    document.compact!

    assert_equal 0, document.updates.count, "the healed batch compacted, quarantine included"
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
