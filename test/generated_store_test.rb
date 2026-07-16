# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require "active_record"

# The generated store is app code, but its compaction logic is the blessed
# answer to "doesn't on_load replay the whole history?" — so its behavior is
# pinned here against a real database, not just asserted as template text.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :yrby_document_updates do |t|
    t.binary :payload, null: false
    t.string :document_key, null: false, index: true
    t.datetime :created_at, null: false
  end
end

ApplicationRecord = Class.new(ActiveRecord::Base) { self.abstract_class = true }

generated = File.expand_path("../lib/generators/yrby/install/templates", __dir__)
load File.join(generated, "yrby_document_update.rb")
load File.join(generated, "yrby_document_store.rb")

class GeneratedStoreTest < Minitest::Test
  # Two concurrent clients editing the same Y.Text field, captured from real
  # Y.js. Their merge must contain both writes regardless of row order.
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  def setup
    YrbyDocumentUpdate.delete_all
    YrbyDocumentStore.compact_every = 500
  end

  def read_back(key)
    doc = Y::Doc.new
    doc.apply_update(YrbyDocumentStore.load(key))
    doc.read_text("content")
  end

  def test_load_returns_nil_for_an_unknown_document
    assert_nil YrbyDocumentStore.load("nope")
  end

  def test_append_then_load_round_trips
    YrbyDocumentStore.append("k", CLIENT_ONE)

    assert_equal "from doc1", read_back("k")
  end

  def test_load_merges_concurrent_updates
    YrbyDocumentStore.append("k", CLIENT_ONE)
    YrbyDocumentStore.append("k", CLIENT_TWO)

    merged = read_back("k")

    assert_includes merged, "from doc1"
    assert_includes merged, "from doc2"
  end

  def test_compact_collapses_rows_and_preserves_state
    YrbyDocumentStore.append("k", CLIENT_ONE)
    YrbyDocumentStore.append("k", CLIENT_TWO)
    before = read_back("k")

    YrbyDocumentStore.compact!("k")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count
    assert_equal before, read_back("k")
  end

  def test_append_triggers_compaction_at_the_threshold
    YrbyDocumentStore.compact_every = 2
    YrbyDocumentStore.append("k", CLIENT_ONE)

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count, "below threshold: no compaction"

    YrbyDocumentStore.append("k", CLIENT_TWO)

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count, "threshold append compacts"
    assert_includes read_back("k"), "from doc2"
  end

  def test_compact_is_a_noop_below_two_rows
    YrbyDocumentStore.append("k", CLIENT_ONE)
    snapshot_id = YrbyDocumentUpdate.last.id

    YrbyDocumentStore.compact!("k")

    assert_equal [snapshot_id], YrbyDocumentUpdate.where(document_key: "k").pluck(:id)
  end

  def test_redelivered_update_compacts_away
    # At-least-once delivery means the same update can be recorded twice;
    # CRDT idempotence makes the duplicate a no-op in the merged state.
    YrbyDocumentStore.append("k", CLIENT_ONE)
    YrbyDocumentStore.append("k", CLIENT_ONE)

    YrbyDocumentStore.compact!("k")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "k").count
    assert_equal "from doc1", read_back("k")
  end

  def test_compaction_scopes_to_one_document
    YrbyDocumentStore.append("a", CLIENT_ONE)
    YrbyDocumentStore.append("b", CLIENT_ONE)
    YrbyDocumentStore.append("b", CLIENT_TWO)

    YrbyDocumentStore.compact!("b")

    assert_equal 1, YrbyDocumentUpdate.where(document_key: "a").count
    assert_equal 1, YrbyDocumentUpdate.where(document_key: "b").count
    assert_equal "from doc1", read_back("a")
  end
end
