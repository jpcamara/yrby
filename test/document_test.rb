# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"

# Y::Document is the identity a transport key points at and the owner of its
# update log; Y::DocumentUpdate is the Y::UpdateLog rows keyed by document_id.
# Exercised here against a real database, exactly as the generated channel
# uses them (load_state/append by key).
class DocumentTest < Minitest::Test
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
  end

  def test_append_creates_the_document_and_load_state_round_trips
    Y::Document.append("room-1", CLIENT_ONE)
    Y::Document.append("room-1", CLIENT_TWO)

    assert_equal 1, Y::Document.count
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state("room-1"))

    assert_equal "from doc1from doc2", doc.read_text("content")
  end

  def test_load_state_is_nil_for_an_unknown_key
    assert_nil Y::Document.load_state("nope")
  end

  def test_documents_are_scoped_by_key
    Y::Document.append("a", CLIENT_ONE)
    Y::Document.append("b", CLIENT_TWO)

    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state("a"))

    assert_equal "from doc1", doc.read_text("content")
  end

  def test_destroying_a_document_sweeps_its_log
    Y::Document.append("room-1", CLIENT_ONE)

    Y::Document.find_by(key: "room-1").destroy!

    assert_equal 0, Y::DocumentUpdate.count
  end

  def test_record_binding_is_optional
    Y::Document.append("room-1", CLIENT_ONE)

    assert_nil Y::Document.find_by(key: "room-1").record_type, "key-only documents carry no record"
  end

  def test_update_log_is_keyed_by_document_id
    assert_equal :document_id, Y::DocumentUpdate.key_column
    assert_includes Y::DocumentUpdate.included_modules, Y::UpdateLog
  end
end
