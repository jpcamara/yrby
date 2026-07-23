# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "active_record"

# Y::UpdateLog is the blessed answer to "doesn't on_load replay
# the whole history?" — its behavior is pinned here against a real database,
# included into a model exactly the way the install generator generates it.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :yrby_document_updates do |t|
    t.binary :payload, null: false
    t.string :document_key, null: false, index: true
    t.datetime :created_at, null: false
  end
end

require "y/action_cable"

class YrbyDocumentUpdate < ActiveRecord::Base
  self.table_name = "yrby_document_updates"
  include Y::UpdateLog
end

class UpdateLogTest < Minitest::Test
  # Two concurrent clients editing the same Y.Text field, captured from real
  # Y.js. Their merge must contain both writes regardless of row order.
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  def setup
    YrbyDocumentUpdate.delete_all
    YrbyDocumentUpdate.compact_every = 500
  end

  def read_back(key)
    doc = Y::Doc.new
    doc.apply_update(YrbyDocumentUpdate.load(key))
    doc.read_text("content")
  end

  def test_load_returns_nil_for_an_unknown_document
    assert_nil YrbyDocumentUpdate.load("nope")
  end

  def test_append_then_load_round_trips
    YrbyDocumentUpdate.append("k", CLIENT_ONE)

    assert_equal "from doc1", read_back("k")
  end

  def test_load_merges_concurrent_updates
    YrbyDocumentUpdate.append("k", CLIENT_ONE)
    YrbyDocumentUpdate.append("k", CLIENT_TWO)

    merged = read_back("k")

    assert_includes merged, "from doc1"
    assert_includes merged, "from doc2"
  end

  def test_compact_collapses_rows_and_preserves_state
    YrbyDocumentUpdate.append("k", CLIENT_ONE)
    YrbyDocumentUpdate.append("k", CLIENT_TWO)
    before = read_back("k")

    YrbyDocumentUpdate.compact!("k")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count
    assert_equal before, read_back("k")
  end

  def test_append_triggers_compaction_at_the_threshold
    YrbyDocumentUpdate.compact_every = 2
    YrbyDocumentUpdate.append("k", CLIENT_ONE)

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count, "below threshold: no compaction"

    YrbyDocumentUpdate.append("k", CLIENT_TWO)

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count, "threshold append compacts"
    assert_includes read_back("k"), "from doc2"
  end

  def test_compact_is_a_noop_below_two_rows
    YrbyDocumentUpdate.append("k", CLIENT_ONE)
    snapshot_id = YrbyDocumentUpdate.last.id

    YrbyDocumentUpdate.compact!("k")

    assert_equal [snapshot_id], YrbyDocumentUpdate.where(document_key: "k").pluck(:id)
  end

  def test_redelivered_update_compacts_away
    # At-least-once delivery means the same update can be recorded twice;
    # CRDT idempotence makes the duplicate a no-op in the merged state.
    YrbyDocumentUpdate.append("k", CLIENT_ONE)
    YrbyDocumentUpdate.append("k", CLIENT_ONE)

    YrbyDocumentUpdate.compact!("k")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count
    assert_equal "from doc1", read_back("k")
  end

  def test_latest_change_at_tracks_the_newest_row
    assert_nil YrbyDocumentUpdate.latest_change_at("nope")

    YrbyDocumentUpdate.append("k", CLIENT_ONE)
    first = YrbyDocumentUpdate.latest_change_at("k")

    refute_nil first

    YrbyDocumentUpdate.append("k", CLIENT_TWO)

    assert_operator YrbyDocumentUpdate.latest_change_at("k"), :>=, first
    assert_nil YrbyDocumentUpdate.latest_change_at("other"), "scoped per document"
  end

  def test_compaction_scopes_to_one_document
    YrbyDocumentUpdate.append("a", CLIENT_ONE)
    YrbyDocumentUpdate.append("b", CLIENT_ONE)
    YrbyDocumentUpdate.append("b", CLIENT_TWO)

    YrbyDocumentUpdate.compact!("b")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "a").count
    assert_equal 1, YrbyDocumentUpdate.where(document_key: "b").count
    assert_equal "from doc1", read_back("a")
  end

  def test_compaction_skips_a_document_with_a_pending_gap
    # A stored gappy update (its dependency never recorded), redelivered
    # once (at-least-once delivery): the snapshot would exclude the pending
    # struct, so compacting would delete the only copy of a gap that could
    # still heal. Compaction must leave the rows alone.
    YrbyDocumentUpdate.append("k", YjsFixtures::Gap::DEPENDENT)
    YrbyDocumentUpdate.append("k", YjsFixtures::Gap::DEPENDENT)

    YrbyDocumentUpdate.compact!("k")

    assert_equal 2, YrbyDocumentUpdate.where(document_key: "k").count,
                 "rows survive while a gap is open"

    # The gap heals (its dependency arrives) and compaction resumes,
    # preserving the healed content.
    YrbyDocumentUpdate.append("k", YjsFixtures::Gap::FIRST)
    YrbyDocumentUpdate.compact!("k")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count,
                 "compaction resumes once the gap heals"
    healed = Y::Doc.new
    healed.apply_update(YrbyDocumentUpdate.load("k"))

    assert_equal "ab", healed.read_text("notepad"), "the healed gap survived compaction"
  end
end
