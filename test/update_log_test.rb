# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "active_record"

# Y::UpdateLog is the blessed answer to "doesn't on_load replay
# the whole history?" — its behavior is pinned here against a real database,
# included into a model exactly the way the install generator generates it.
require_relative "support/active_record"

require "y/action_cable"

class ModuleKeyedUpdate < ActiveRecord::Base
  self.table_name = "module_keyed_updates"
  include Y::UpdateLog
end

class UpdateLogTest < Minitest::Test
  # Two concurrent clients editing the same Y.Text field, captured from real
  # Y.js. Their merge must contain both writes regardless of row order.
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  def setup
    ModuleKeyedUpdate.delete_all
    ModuleKeyedUpdate.compact_every = 500
  end

  def read_back(key)
    doc = Y::Doc.new
    doc.apply_update(ModuleKeyedUpdate.load(key))
    doc.read_text("content")
  end

  def test_load_returns_nil_for_an_unknown_document
    assert_nil ModuleKeyedUpdate.load("nope")
  end

  def test_append_then_load_round_trips
    ModuleKeyedUpdate.append("k", CLIENT_ONE)

    assert_equal "from doc1", read_back("k")
  end

  def test_load_merges_concurrent_updates
    ModuleKeyedUpdate.append("k", CLIENT_ONE)
    ModuleKeyedUpdate.append("k", CLIENT_TWO)

    merged = read_back("k")

    assert_includes merged, "from doc1"
    assert_includes merged, "from doc2"
  end

  def test_compact_collapses_rows_and_preserves_state
    ModuleKeyedUpdate.append("k", CLIENT_ONE)
    ModuleKeyedUpdate.append("k", CLIENT_TWO)
    before = read_back("k")

    ModuleKeyedUpdate.compact!("k")

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "k").count
    assert_equal before, read_back("k")
  end

  def test_append_triggers_compaction_at_the_threshold
    ModuleKeyedUpdate.compact_every = 2
    ModuleKeyedUpdate.append("k", CLIENT_ONE)

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "k").count, "below threshold: no compaction"

    ModuleKeyedUpdate.append("k", CLIENT_TWO)

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "k").count, "threshold append compacts"
    assert_includes read_back("k"), "from doc2"
  end

  def test_compact_is_a_noop_below_two_rows
    ModuleKeyedUpdate.append("k", CLIENT_ONE)
    snapshot_id = ModuleKeyedUpdate.last.id

    ModuleKeyedUpdate.compact!("k")

    assert_equal [snapshot_id], ModuleKeyedUpdate.where(document_key: "k").pluck(:id)
  end

  def test_redelivered_update_compacts_away
    # At-least-once delivery means the same update can be recorded twice;
    # CRDT idempotence makes the duplicate a no-op in the merged state.
    ModuleKeyedUpdate.append("k", CLIENT_ONE)
    ModuleKeyedUpdate.append("k", CLIENT_ONE)

    ModuleKeyedUpdate.compact!("k")

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "k").count
    assert_equal "from doc1", read_back("k")
  end

  def test_key_column_is_overridable
    parent_keyed = Class.new(ActiveRecord::Base) do
      self.table_name = "parent_keyed_updates"
      include Y::UpdateLog

      def self.key_column = :parent_id
      def self.name = "ParentKeyedUpdate"
    end
    parent_keyed.append(7, CLIENT_ONE)
    parent_keyed.append(7, CLIENT_TWO)

    doc = Y::Doc.new
    doc.apply_update(parent_keyed.load(7))

    assert_equal "from doc1from doc2", doc.read_text("content")
    parent_keyed.compact!(7)

    assert_equal 1, parent_keyed.where(parent_id: 7).count
    refute_nil parent_keyed.latest_change_at(7)
    assert_nil parent_keyed.latest_change_at(8)
  end

  def test_latest_change_at_tracks_the_newest_row
    assert_nil ModuleKeyedUpdate.latest_change_at("nope")

    ModuleKeyedUpdate.append("k", CLIENT_ONE)
    first = ModuleKeyedUpdate.latest_change_at("k")

    refute_nil first

    ModuleKeyedUpdate.append("k", CLIENT_TWO)

    assert_operator ModuleKeyedUpdate.latest_change_at("k"), :>=, first
    assert_nil ModuleKeyedUpdate.latest_change_at("other"), "scoped per document"
  end

  def test_compaction_scopes_to_one_document
    ModuleKeyedUpdate.append("a", CLIENT_ONE)
    ModuleKeyedUpdate.append("b", CLIENT_ONE)
    ModuleKeyedUpdate.append("b", CLIENT_TWO)

    ModuleKeyedUpdate.compact!("b")

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "a").count
    assert_equal 1, ModuleKeyedUpdate.where(document_key: "b").count
    assert_equal "from doc1", read_back("a")
  end

  def test_compaction_skips_a_document_with_a_pending_gap
    # A stored gappy update (its dependency never recorded), redelivered
    # once (at-least-once delivery): the snapshot would exclude the pending
    # struct, so compacting would delete the only copy of a gap that could
    # still heal. Compaction must leave the rows alone.
    ModuleKeyedUpdate.append("k", YjsFixtures::Gap::DEPENDENT)
    ModuleKeyedUpdate.append("k", YjsFixtures::Gap::DEPENDENT)

    ModuleKeyedUpdate.compact!("k")

    assert_equal 2, ModuleKeyedUpdate.where(document_key: "k").count,
                 "rows survive while a gap is open"

    # The gap heals (its dependency arrives) and compaction resumes,
    # preserving the healed content.
    ModuleKeyedUpdate.append("k", YjsFixtures::Gap::FIRST)
    ModuleKeyedUpdate.compact!("k")

    assert_equal 1, ModuleKeyedUpdate.where(document_key: "k").count,
                 "compaction resumes once the gap heals"
    healed = Y::Doc.new
    healed.apply_update(ModuleKeyedUpdate.load("k"))

    assert_equal "ab", healed.read_text("notepad"), "the healed gap survived compaction"
  end
end
