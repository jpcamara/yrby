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

# The channel that ships in the gem. It takes a signed grant and stores
# through Y::Document, and the app writes no channel. Driven through Action
# Cable's channel test harness against a test cable adapter.
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
    @original_authorizer = Y::DocumentChannel.document_authorizer
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    @page = Page.create!(title: "granted")
    stub_connection
  end

  def teardown
    Y::DocumentChannel.document_authorizer = @original_authorizer
    Page.delete_all
  end

  def grant = @page.collaborative_sgid(:body)

  def test_session_routing_nonce_does_not_select_or_authorize_a_document
    subscribe grant: grant, name: "body", session_id: "browser-session"

    assert_predicate subscription, :confirmed?
    assert_equal @page.collaborative_document(:body).document, subscription.send(:document).document
  end

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

  def test_authorizer_requires_a_block_and_preserves_the_existing_policy
    Y::DocumentChannel.authorize_document { false }
    policy = Y::DocumentChannel.document_authorizer

    assert_raises(ArgumentError) { Y::DocumentChannel.authorize_document }
    assert_same policy, Y::DocumentChannel.document_authorizer
  end

  def test_authorizer_receives_the_record_attribute_and_connection_context
    stub_connection current_user: "granted"
    Y::DocumentChannel.authorize_document do |record, name|
      record.title == current_user && name == "body"
    end
    subscribe grant: grant, name: "body"

    assert_predicate subscription, :confirmed?
    perform :receive, update_frame

    assert_includes transmissions, { "ack" => 7 }
    assert_equal 1, Y::DocumentUpdate.count
  end

  # The row assertion is the important one, and it pins the order the channel
  # checks things in. Asking a built-in attribute for its document key creates
  # the row, so the policy has to run before the key is derived.
  def test_valid_grant_does_not_bypass_policy_or_create_a_document
    stub_connection current_user: "someone else"
    Y::DocumentChannel.authorize_document { |record, _name| record.title == current_user }
    subscribe grant: grant, name: "body"

    assert_predicate subscription, :rejected?
    assert_empty subscription.streams
    assert_empty transmissions
    assert_equal 0, Y::Document.count
  end

  def test_nil_policy_result_denies_access
    Y::DocumentChannel.authorize_document { nil }
    subscribe grant: grant, name: "body"

    assert_predicate subscription, :rejected?
  end

  def test_policy_can_deny_one_attribute_while_the_grant_is_valid
    Y::DocumentChannel.authorize_document { |_record, name| name == "notes" }
    subscribe grant: grant, name: "body"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  def test_invalid_grant_never_calls_the_policy
    Y::DocumentChannel.authorize_document { raise "must not be called" }
    subscribe grant: "invalid", name: "body"

    assert_predicate subscription, :rejected?
  end

  def test_policy_is_inherited_and_a_subclass_can_replace_it
    parent = Class.new(Y::DocumentChannel)
    parent.authorize_document { false }
    child = Class.new(parent)

    assert_same parent.document_authorizer, child.document_authorizer
    child.authorize_document { true }

    refute_same parent.document_authorizer, child.document_authorizer
    assert_nil Y::DocumentChannel.document_authorizer
  end

  # The policy runs once, at subscribe, and the subscription is the grant from
  # then on. These tests pin that down, tradeoff included. An app that needs
  # to cut off access before the client disconnects has to stop the
  # subscription itself, and short-lived grants limit how long a stale one can
  # live.
  def test_permission_changes_do_not_disturb_an_open_subscription
    stub_connection current_user: "granted"
    Y::DocumentChannel.authorize_document { |record, _name| record.title == current_user }
    subscribe grant: grant, name: "body"
    @page.update!(title: "revoked")
    perform :receive, update_frame

    assert_includes transmissions, { "ack" => 7 }
    assert_equal 1, Y::DocumentUpdate.count
  end

  def test_the_policy_is_not_consulted_again_for_a_sync_request
    Y::DocumentChannel.authorize_document { |record, _name| record.title == "granted" }
    subscribe grant: grant, name: "body"
    @page.update!(title: "revoked")
    consulted = false
    Y::DocumentChannel.authorize_document { |_record, _name| consulted = true }
    perform :receive, "update" => Base64.strict_encode64(Y::Doc.new.sync_step1)

    refute consulted, "the policy ran on an incoming frame"
  end

  def test_grant_expiry_bounds_new_subscriptions_not_open_ones
    token = @page.to_sgid(for: Y::Collaborative.sgid_purpose(:body), expires_in: 1.minute).to_s
    subscribe grant: token, name: "body"
    travel 2.minutes do
      perform :receive, update_frame

      assert_equal 1, Y::DocumentUpdate.count, "an open subscription keeps working"

      # A new subscription with the same expired grant is refused.
      @subscription = nil
      subscribe grant: token, name: "body"

      assert_predicate subscription, :rejected?
    end
  end

  def test_a_frame_without_a_subscription_is_refused
    stub_connection current_user: "someone else"
    Y::DocumentChannel.authorize_document { |record, _name| record.title == current_user }
    params = { grant: grant, name: "body" }.with_indifferent_access
    @subscription = Y::DocumentChannel.new(connection, "stateless", params)
    @subscription.singleton_class.include(ActionCable::Channel::ChannelStub)
    perform :receive, update_frame

    assert_equal 0, Y::Document.count
    assert_subscription_stopped
  end

  # A frame that arrives without an authorized subscription is refused even
  # when the grant is valid. The subscription holds the decision, not the
  # grant.
  def test_a_valid_grant_alone_does_not_authorize_a_frame
    stub_connection current_user: "granted"
    Y::DocumentChannel.authorize_document { |record, _name| record.title == current_user }
    params = { grant: grant, name: "body" }.with_indifferent_access
    @subscription = Y::DocumentChannel.new(connection, "stateless", params)
    @subscription.singleton_class.include(ActionCable::Channel::ChannelStub)
    perform :receive, update_frame

    assert_equal 0, Y::DocumentUpdate.count
    assert_empty transmissions
    assert_subscription_stopped
  end

  def test_policy_exception_during_subscription_fails_closed
    Y::DocumentChannel.authorize_document { raise "policy unavailable" }

    assert_raises(RuntimeError) { subscribe grant: grant, name: "body" }
    assert_equal 0, Y::Document.count
    assert_empty transmissions
    assert_subscription_stopped
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

    document = secret.collaborative_document(:body)

    assert_instance_of Y::EncryptedDocument, document.document
    doc = Y::Doc.new
    doc.apply_update(document.load_state)

    refute_empty doc.read_text("content").to_s, "the encrypted path round-trips the document"

    # The recorded bytes are ciphertext at rest, so reading them through the
    # plain classes gives back garbage, not the document. Each document has
    # one access path.
    raw = Y::DocumentUpdate.find_by!(document_id: document.document.id).payload

    refute_equal update, raw, "the stored payload must not be the plaintext delta"
    assert_raises(StandardError, "the plain path reads ciphertext, not a document") do
      Y::Document.load_state(document.key)
    end
  ensure
    SecretPage.delete_all
  end

  def test_document_accessor_uses_plain_storage_for_undeclared_attributes
    document = @page.collaborative_document(:body)

    assert_instance_of Y::Collaborative::Attribute, document
    assert_instance_of Y::Document, document.document
    assert_equal document.document, @page.collaborative_document("body").document
    assert_equal @page, document.record
  end

  def test_encrypted_accessor_writes_are_readable_through_the_channel
    secret = SecretPage.create!(title: "accessor")
    secret.collaborative_document(:body).append(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    subscribe grant: secret.collaborative_sgid(:body), name: "body"

    client = Y::Doc.new
    perform :receive, "update" => Base64.strict_encode64(client.sync_step1)
    reply = transmissions.last.fetch("update")
    client.handle_sync_message(Base64.strict_decode64(reply))

    refute_empty client.read_text("content").to_s
  ensure
    SecretPage.delete_all
  end

  def test_storage_declarations_are_inherited_without_mutating_the_parent
    child = Class.new(SecretPage)
    child.has_collaborative_document :notes, encrypted: true

    assert_equal Y::EncryptedDocument, child.collaborative_document_class(:body)
    assert_equal Y::EncryptedDocument, child.collaborative_document_class("notes")
    assert_equal Y::Document, SecretPage.collaborative_document_class(:notes)
  end

  private

  def update_frame
    { "update" => Base64.strict_encode64(Y.wrap_update(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)), "id" => 7 }
  end

  def assert_subscription_stopped
    assert_predicate subscription, :rejected?
    assert_predicate subscription, :unsubscribed?
    assert_empty subscription.streams
    assert connection.transmissions.any? { |message| message[:type] == "reject_subscription" },
           "the client must receive a rejection to preserve its pending edits"
  end
end
