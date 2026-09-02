# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "action_cable"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
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
end
