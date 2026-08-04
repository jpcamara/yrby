# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/encrypted_document"
require_relative "../app/models/y/encrypted_document_update"

# Y::EncryptedDocument stores state and payloads through Active Record
# encryption on the same tables as Y::Document. The whole storage design
# (append, load, compaction, record binding) must behave identically, and
# the raw columns must hold ciphertext.
class EncryptedDocumentTest < Minitest::Test
  CLIENT_ONE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
  CLIENT_TWO = YjsFixtures::TwoDocsMerged::DOC2_UPDATE

  class Page < ActiveRecord::Base
    self.table_name = "pages"
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    Page.delete_all
  end

  def read_back(state)
    doc = Y::Doc.new
    doc.apply_update(state)
    doc.read_text("content")
  end

  def test_append_and_load_state_round_trip
    Y::EncryptedDocument.append("room-1", CLIENT_ONE)
    Y::EncryptedDocument.append("room-1", CLIENT_TWO)

    assert_equal "from doc1from doc2", read_back(Y::EncryptedDocument.load_state("room-1"))
  end

  def test_payloads_are_ciphertext_at_rest
    Y::EncryptedDocument.append("room-1", CLIENT_ONE)

    raw = Y::Document.connection.select_value("SELECT payload FROM y_document_updates LIMIT 1")

    refute_equal CLIENT_ONE, raw, "raw column must not hold the plaintext delta"
    assert_includes raw, '"p":', "expected the Active Record encryption envelope"
  end

  def test_compaction_round_trips_and_state_is_ciphertext_at_rest
    document = Y::EncryptedDocument.locate!("room-1")
    document.append(CLIENT_ONE)
    document.append(CLIENT_TWO)
    before = read_back(document.load_state)

    document.compact!

    assert_equal 0, document.updates.count, "tail compacted"
    assert_equal before, read_back(document.load_state)

    raw = Y::Document.connection.select_value("SELECT state FROM y_documents LIMIT 1")

    refute_nil raw
    assert_includes raw, '"p":', "expected the Active Record encryption envelope"
  end

  def test_load_state_returns_decrypted_state_verbatim_when_the_tail_is_empty
    document = Y::EncryptedDocument.locate!("room-1")
    document.append(CLIENT_ONE)
    document.compact!

    assert_equal "from doc1", read_back(document.load_state)
  end

  def test_for_binds_records_like_the_plain_class
    page = Page.create!
    document = Y::EncryptedDocument.for(page, :body)

    assert_instance_of Y::EncryptedDocument, document
    assert_equal page, document.record
    assert_equal "encrypted_document_test/page/#{page.id}/body", document.key
    assert_equal document, Y::EncryptedDocument.for(page, :body)
  end

  def test_the_plain_class_reads_an_encrypted_row_as_ciphertext
    # One access path per document: this documents what mixing them does.
    document = Y::EncryptedDocument.locate!("room-1")
    document.append(CLIENT_ONE)
    document.compact!

    refute_equal Y::EncryptedDocument.load_state("room-1"),
                 Y::Document.load_state("room-1"),
                 "the plain class must not silently decrypt"
  end
end
