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

  def test_attribute_uses_the_existing_row_and_declared_storage
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

  # The page, the agent, and a Ruby client all subscribe to the channel the
  # document names, so an app's own subclass is declared once.
  def test_the_channel_is_the_one_the_model_declared
    page_class = Class.new(Page) { has_collaborative_document :body, channel: "PageDocumentChannel" }
    custom = page_class.create!(title: "custom")

    assert_equal "PageDocumentChannel", custom.collaborative_document(:body).channel
    assert_equal "Y::DocumentChannel", custom.collaborative_document(:secret).channel
    assert_equal "Y::DocumentChannel", @page.collaborative_document(:body).channel
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
