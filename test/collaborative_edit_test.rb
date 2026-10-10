# frozen_string_literal: true

require_relative "document_channel_test"

# Editing a document from Ruby: the change is recorded in the document's rows
# and broadcast on its stream, the same path a browser edit takes.
class CollaborativeEditTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  Page = DocumentChannelTest::Page
  SecretPage = DocumentChannelTest::SecretPage

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    Y::EncryptedDocumentUpdate.delete_all
    Y::EncryptedDocument.delete_all
    @page = Page.create!(title: "editable")
  end

  def teardown
    Page.delete_all
  end

  def frame(update) = { "update" => Base64.strict_encode64(Y.wrap_update(update)) }

  def test_an_edit_is_recorded_and_broadcast
    body = @page.collaborative_document(:body)
    update = body.edit { |doc| doc.get_text("content").push("from ruby") }

    assert_equal "from ruby", body.y_doc.read_text("content")
    assert_equal 1, Y::DocumentUpdate.count
    assert_broadcast_on(Y::ActionCable.stream_name(body.key), frame(update))
  end

  def test_an_edit_that_changes_nothing_records_and_broadcasts_nothing
    body = @page.collaborative_document(:body)

    assert_no_broadcasts(Y::ActionCable.stream_name(body.key)) do
      assert_nil(body.edit { |doc| doc.get_text("content") })
    end
    assert_equal 0, Y::DocumentUpdate.count
  end

  def test_edits_build_on_each_other
    body = @page.collaborative_document(:body)
    body.edit { |doc| doc.get_text("content").push("one\n") }
    body.edit { |doc| doc.get_text("content").push("two\n") }

    assert_equal "one\ntwo\n", body.y_doc.read_text("content")
    assert_equal 2, Y::DocumentUpdate.count
  end

  def test_an_edit_merges_with_a_browser_edit_it_never_saw
    body = @page.collaborative_document(:body)
    browser = Y::Doc.new
    browser_update = browser.diff { browser.get_text("content").push("typed ") }
    ruby_update = body.edit { |doc| doc.get_text("content").push("written") }
    body.append(browser_update)

    merged = body.y_doc.read_text("content")
    browser.apply_update(ruby_update)

    assert_equal merged, browser.get_text("content").to_s
    assert_includes merged, "typed "
    assert_includes merged, "written"
  end

  def test_an_encrypted_document_is_edited_through_its_own_rows
    page = SecretPage.find(@page.id)
    body = page.collaborative_document(:body)
    update = body.edit { |doc| Y::Lexxy.append_paragraph(doc, "secret") }

    assert_equal update, Y::EncryptedDocumentUpdate.sole.payload
    refute_equal update, Y::DocumentUpdate.sole.payload
    assert_equal "<p>secret</p>", Y::Lexxy.new(body.y_doc).to_html("root")
  end

  def test_a_subscribed_browser_gets_the_edit_on_its_stream
    stub_connection
    subscribe grant: @page.collaborative_sgid(:body), name: "body"
    body = @page.collaborative_document(:body)

    assert_predicate subscription, :confirmed?
    assert_has_stream Y::ActionCable.stream_name(body.key)

    update = body.edit { |doc| doc.get_text("content").push("hello") }

    assert_broadcast_on(Y::ActionCable.stream_name(body.key), frame(update))
  end
end
