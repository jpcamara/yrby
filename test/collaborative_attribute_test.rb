# frozen_string_literal: true

require_relative "document_channel_test"

class CollaborativeAttributeTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class Store
    attr_reader :updates

    def initialize
      @updates = Hash.new { |hash, key| hash[key] = [] }
    end

    def load(record, name)
      doc = Y::Doc.new
      updates[[record.id, name]].each { |update| doc.apply_update(update) }
      doc.encode_state_as_update
    end

    def write(record, name, update)
      updates[[record.id, name]] << update
    end
  end

  STORE = Store.new

  class Page < DocumentChannelTest::Page
    has_collaborative_document :external, storage: STORE
    has_collaborative_document :secret, encrypted: true
  end

  UPDATE = YjsFixtures::TwoDocsMerged::DOC1_UPDATE

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    STORE.updates.clear
    @page = Page.create!(title: "bound storage")
    stub_connection
  end

  def teardown
    Page.delete_all
  end

  def test_custom_channel_writes_and_ruby_reads_share_the_declared_store_without_database_rows
    attribute = @page.collaborative_document(:external)
    subscribe grant: @page.collaborative_sgid(:external), name: "external"
    perform :receive, "update" => Base64.strict_encode64(Y.wrap_update(UPDATE)), "id" => 9

    assert_includes transmissions, { "ack" => 9 }
    assert_equal "from doc1", attribute.doc.read_text("content")
    assert_equal [UPDATE], STORE.updates[[@page.id, "external"]]
    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count
    assert_has_stream "yrby:#{Y::Document.key_for(@page, :external)}"
  end

  def test_custom_ruby_appends_are_served_by_the_channel
    @page.collaborative_document(:external).append(UPDATE)
    subscribe grant: @page.collaborative_sgid(:external), name: "external"
    client = Y::Doc.new
    perform :receive, "update" => Base64.strict_encode64(client.sync_step1)
    client.handle_sync_message(Base64.strict_decode64(transmissions.last.fetch("update")))

    assert_equal "from doc1", client.read_text("content")
    assert_equal 0, Y::Document.count
  end

  def test_failed_custom_write_is_neither_acknowledged_nor_broadcast
    subscribe grant: @page.collaborative_sgid(:external), name: "external"
    before = transmissions.dup
    STORE.stub(:write, ->(*) { raise IOError, "store unavailable" }) do
      ActionCable.server.stub(:broadcast, ->(*) { flunk "must persist before broadcast" }) do
        assert_raises(IOError) do
          perform :receive, "update" => Base64.strict_encode64(Y.wrap_update(UPDATE)), "id" => 10
        end
      end
    end

    assert_equal before, transmissions
    assert_empty STORE.updates[[@page.id, "external"]]
  end

  def test_bound_access_supports_native_reads_and_preserves_existing_storage_keys
    stored = Y::Document.create!(record: @page, name: "body", key: "existing-room")
    name = +"body"
    attribute = @page.collaborative_document(name)
    name.replace("external")
    attribute.append(UPDATE)

    assert_equal "body", attribute.name
    assert_predicate attribute.name, :frozen?
    assert_equal stored, attribute.document
    assert_equal "existing-room", attribute.key
    assert_equal "from doc1", attribute.doc.read_text("content")
    refute_same attribute.doc, attribute.doc
    @page.collaborative_document(:secret).append(UPDATE)

    assert_equal "from doc1", @page.collaborative_document(:secret).doc.read_text("content")
    assert_instance_of Y::EncryptedDocument, @page.collaborative_document(:secret).document
  end

  def test_key_does_not_create_a_document_row
    attribute = @page.collaborative_document(:body)

    assert_equal Y::Document.key_for(@page, "body"), attribute.key
    assert_equal 0, Y::Document.count
  end

  def test_custom_storage_cannot_silently_fall_back_to_plain_database_access
    assert_raises(ArgumentError) { @page.collaborative_document(:external).document }
    assert_raises(ArgumentError) { Page.collaborative_document_class(:external) }
    assert_raises(ArgumentError) { Page.has_collaborative_document(:bad, storage: Object.new) }
    assert_raises(ArgumentError) { Page.has_collaborative_document(:bad, storage: STORE, encrypted: true) }
    assert_raises(ArgumentError) { Page.new.collaborative_document(:body) }
  end

  def test_inherited_storage_configuration_does_not_mutate_its_parent
    child = Class.new(Page)
    child.has_collaborative_document :external, encrypted: true

    assert_equal STORE, Page.collaborative_document_options.dig("external", :storage)
    assert_nil child.collaborative_document_options.dig("external", :storage)
    assert_equal Y::EncryptedDocument, child.collaborative_document_class(:external)
    assert_predicate child.collaborative_document_options, :frozen?
    assert_predicate child.collaborative_document_options.fetch("external"), :frozen?
  end
end
