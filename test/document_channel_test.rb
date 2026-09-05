# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "action_cable"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/encrypted_document"
require_relative "../app/models/y/encrypted_document_update"
require "y/collaborative"
require "global_id"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

require_relative "../app/channels/y/document_channel"

# No Rails app here: point the cable server at the test adapter by hand.
ActionCable.server.config.cable = { "adapter" => "test" }
ActionCable.server.config.logger = Logger.new(File::NULL)

# The gem-shipped channel: a signed grant in, Y::Document storage out, and
# nothing for the app to write. Driven through Action Cable's own channel
# test harness against a test cable adapter.
class DocumentChannelTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  # An attribute the model declared encrypted: the channel must route every
  # load and append for it through Y::EncryptedDocument.
  class SecretPage < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative

    has_collaborative_document :body, encrypted: true
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    @page = Page.create!(title: "granted")
    stub_connection
  end

  def teardown
    Page.delete_all
  end

  def grant = @page.collaborative_sgid(:body)

  def test_a_signed_grant_subscribes_and_gets_the_opening_handshake
    subscribe grant: grant, name: "body"

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
  end

  def test_an_update_is_recorded_through_y_document_and_acked
    subscribe grant: grant, name: "body"
    frame = Y.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    perform :receive, "update" => Base64.strict_encode64(frame), "id" => 3

    assert_includes transmissions, { "ack" => 3 }
    document = Y::Document.find_by!(record: @page, name: "body")
    doc = Y::Doc.new
    doc.apply_update(document.load_state)

    refute_empty doc.read_text("content").to_s
  end

  def test_a_missing_grant_is_rejected
    subscribe name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  def test_a_tampered_grant_is_rejected
    subscribe grant: "#{grant}x", name: "body"

    assert_predicate subscription, :rejected?
  end

  def test_a_grant_for_another_attribute_is_rejected
    subscribe grant: grant, name: "notes"

    assert_predicate subscription, :rejected?, "a :body grant must not open :notes"
  end

  def test_a_grant_for_a_destroyed_record_is_rejected
    token = grant
    @page.destroy!

    subscribe grant: token, name: "body"

    assert_predicate subscription, :rejected?
  end

  # -- storage follows the model's declaration --------------------------------

  def test_the_storage_class_comes_from_the_declaration
    assert_equal Y::EncryptedDocument, SecretPage.collaborative_document_class(:body)
    assert_equal Y::Document, SecretPage.collaborative_document_class(:other), "undeclared attributes stay plain"
    assert_equal Y::Document, Page.collaborative_document_class(:body)
  end

  def test_an_encrypted_attribute_stores_ciphertext_and_still_syncs
    secret = SecretPage.create!(title: "classified")
    subscribe grant: secret.collaborative_sgid(:body), name: "body"

    assert_predicate subscription, :confirmed?

    update = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
    perform :receive, "update" => Base64.strict_encode64(Y.wrap_update(update)), "id" => 4

    assert_includes transmissions, { "ack" => 4 }

    document = Y::EncryptedDocument.find_by!(record: secret, name: "body")
    doc = Y::Doc.new
    doc.apply_update(document.load_state)

    refute_empty doc.read_text("content").to_s, "the encrypted path round-trips the document"

    # The safety property: the recorded bytes are ciphertext at rest, so the
    # plain classes read back garbage, never the document. One access path
    # per document.
    raw = Y::DocumentUpdate.find_by!(document_id: document.id).payload

    refute_equal update, raw, "the stored payload must not be the plaintext delta"
    assert_raises(StandardError, "the plain path reads ciphertext, not a document") do
      Y::Document.load_state(document.key)
    end
  ensure
    SecretPage.delete_all
  end
end
