# frozen_string_literal: true

require_relative "document_channel_test"
require "y/forms"
require_relative "../app/channels/y/forms/fields_channel"

# The channel has_collaborative_fields declares. It is Y::DocumentChannel for
# the field set, and it writes the declared fields to their columns after each
# change.
class FormsFieldsChannelTest < ActionCable::Channel::TestCase
  tests Y::Forms::FieldsChannel

  class Ticket < ActiveRecord::Base
    self.table_name = "tickets"
    include GlobalID::Identification
    include Y::Forms::CollaborativeFields

    enum :status, { triage: "triage", active: "active", done: "done" }
    has_collaborative_fields :status, :priority, :urgent, :due_on, :summary, :description
  end

  # Collaborative, but with no fields declared.
  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  def setup
    @original_authorizer = Y::DocumentChannel.document_authorizer
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    @ticket = Ticket.create!(title: "keep me")
    stub_connection
  end

  def teardown
    Y::DocumentChannel.document_authorizer = @original_authorizer
    Ticket.delete_all
    Page.delete_all
  end

  def test_the_form_helpers_grant_subscribes
    subscribe grant: grant, name: "fields"

    assert_predicate subscription, :confirmed?
    assert transmissions.any? { |m| m["update"].present? }, "expected a SyncStep1 handshake"
  end

  def test_a_change_is_saved_acked_and_written_to_the_columns
    subscribe grant: grant, name: "fields"
    perform :receive, frame(YjsFixtures::FormFields::FULL, 1)

    assert_includes transmissions, { "ack" => 1 }
    assert_equal 1, Y::DocumentUpdate.count
    @ticket.reload

    assert_equal "active", @ticket.status
    assert_equal 7, @ticket.priority
    assert_equal "Fix the flaky spec", @ticket.summary
    assert_equal "keep me", @ticket.title, "an undeclared column is left alone"

    perform :receive, frame(YjsFixtures::FormFields::STATUS_DONE, 2)

    assert_equal "done", @ticket.reload.status
  end

  def test_a_failed_column_write_does_not_fail_the_change
    Ticket.before_save { throw :abort }
    subscribe grant: grant, name: "fields"
    perform :receive, frame(YjsFixtures::FormFields::FULL, 1)

    assert_includes transmissions, { "ack" => 1 }
    assert_equal 1, Y::DocumentUpdate.count, "the change is saved"
    assert_nil @ticket.reload.summary
  ensure
    Ticket.reset_callbacks(:save)
  end

  def test_the_shipped_channels_authorizer_applies
    Y::DocumentChannel.authorize_document { |_record, _name| false }
    subscribe grant: grant, name: "fields"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  def test_a_grant_for_another_attribute_opens_nothing
    subscribe grant: @ticket.collaborative_document(:notes).grant, name: "notes"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  def test_a_model_without_collaborative_fields_opens_nothing
    page = Page.create!(title: "plain")
    subscribe grant: page.collaborative_document(:fields).grant, name: "fields"

    assert_predicate subscription, :rejected?
    assert_equal 0, Y::Document.count
  end

  def test_clients_can_only_reach_subscribed_and_receive
    assert_equal Set["subscribed", "receive"], Y::Forms::FieldsChannel.action_methods
  end

  private

  def grant = @ticket.collaborative_document(:fields).grant

  def frame(update, id)
    { "update" => Base64.strict_encode64(Y.wrap_update(update)), "id" => id }
  end
end
