# frozen_string_literal: true

require_relative "document_channel_test"

# Editing a document from Ruby: the change is recorded through the declared
# storage and broadcast on the document's stream, the same path a browser
# edit takes. A block that changes nothing does nothing.
class CollaborativeEditTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class Store
    attr_reader :updates

    def initialize = @updates = Hash.new { |hash, key| hash[key] = [] }

    def load(record, name)
      doc = Y::Doc.new
      updates[[record.id, name]].each { |update| doc.apply_update(update) }
      doc.encode_state_as_update
    end

    def write(record, name, update) = updates[[record.id, name]] << update
  end

  STORE = Store.new

  class Page < DocumentChannelTest::Page
    has_collaborative_document :external, storage: STORE
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    STORE.updates.clear
    @page = Page.create!(title: "editable")
  end

  def teardown
    Page.delete_all
  end

  def test_an_edit_is_recorded_and_broadcast
    attribute = @page.collaborative_document(:body)
    update = attribute.edit { |doc| doc.get_text("content").push("from ruby") }

    assert_equal "from ruby", @page.collaborative_document(:body).doc.read_text("content")
    assert_equal 1, Y::DocumentUpdate.count
    assert_broadcast_on("yrby:#{attribute.key}", "update" => Base64.strict_encode64(Y.wrap_update(update)))
  end

  def test_an_edit_that_changes_nothing_records_and_broadcasts_nothing
    attribute = @page.collaborative_document(:body)

    assert_no_broadcasts("yrby:#{attribute.key}") do
      result = attribute.edit { |document| document.get_text("content") }

      assert_nil result
    end
    assert_equal 0, Y::DocumentUpdate.count
  end

  def test_an_edit_through_custom_storage_uses_the_adapter
    attribute = @page.collaborative_document(:external)
    update = attribute.edit { |doc| doc.get_text("content").push("adapter") }

    assert_equal [update], STORE.updates[[@page.id, "external"]]
    assert_equal "adapter", attribute.doc.read_text("content")
    assert_equal 0, Y::Document.count
    assert_broadcast_on("yrby:#{attribute.key}", "update" => Base64.strict_encode64(Y.wrap_update(update)))
  end

  def test_edits_build_on_each_other
    attribute = @page.collaborative_document(:body)
    attribute.edit { |doc| doc.get_text("content").push("one\n") }
    attribute.edit { |doc| doc.get_text("content").push("two\n") }

    assert_equal "one\ntwo\n", attribute.doc.read_text("content")
    assert_equal 2, Y::DocumentUpdate.count
  end
end
