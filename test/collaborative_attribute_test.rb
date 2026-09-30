# frozen_string_literal: true

require_relative "document_channel_test"

class CollaborativeAttributeTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class Page < DocumentChannelTest::Page
    has_collaborative_document :secret, encrypted: true
  end

  UPDATE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    @page = Page.create!(title: "bound storage")
    stub_connection
  end

  def teardown
    Page.delete_all
  end

  def test_bound_access_supports_native_reads_and_preserves_existing_storage_keys
    stored = Y::Document.create!(record: @page, name: "body", key: "existing-room")
    name = +"body"
    attribute = @page.collaborative_document(name)
    name.replace("other")
    attribute.append(UPDATE)

    assert_equal "body", attribute.name
    assert_predicate attribute.name, :frozen?
    assert_equal stored, attribute.document_row
    assert_equal "existing-room", attribute.key
    assert_equal "from doc1", attribute.y_doc.read_text("content")
    refute_same attribute.y_doc, attribute.y_doc
    @page.collaborative_document(:secret).append(UPDATE)

    assert_equal "from doc1", @page.collaborative_document(:secret).y_doc.read_text("content")
    assert_instance_of Y::EncryptedDocument, @page.collaborative_document(:secret).document_row
  end

  def test_key_does_not_create_a_document_row
    attribute = @page.collaborative_document(:body)

    assert_equal Y::Document.key_for(@page, "body"), attribute.key
    assert_equal 0, Y::Document.count
  end

  def test_collaboration_requires_a_persisted_record
    assert_raises(ArgumentError) { Page.new.collaborative_document(:body) }
  end

  def test_inherited_storage_configuration_does_not_mutate_its_parent
    child = Class.new(Page)
    child.has_collaborative_document :body, encrypted: true

    assert_equal Y::Document, Page.collaborative_document_class(:body)
    assert_equal Y::EncryptedDocument, child.collaborative_document_class(:body)
    assert_equal Y::EncryptedDocument, child.collaborative_document_class(:secret)
    assert_predicate child.collaborative_document_options, :frozen?
    assert_predicate child.collaborative_document_options.fetch("body"), :frozen?
  end
end
