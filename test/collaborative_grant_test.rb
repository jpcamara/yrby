# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# Tests for the signed grant behind record-backed documents. A page renders
# collaborative_document(:attr).grant, and a channel looks the record up with
# Y::Collaborative.locate. The token's purpose names the attribute, so a token
# for one attribute can't open another.
class CollaborativeGrantTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  include ActiveSupport::Testing::Deprecation

  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  def setup
    @page = Page.create!(title: "grant page")
  end

  def teardown
    Page.delete_all
  end

  def test_grant_round_trips_for_its_own_attribute_only
    grant = @page.collaborative_document(:body).grant

    assert_equal @page, Y::Collaborative.locate(grant, :body)
    assert_nil Y::Collaborative.locate(grant, :other_field),
               "a :body token must not locate the record for another attribute"
  end

  def test_grant_purpose_names_the_attribute
    assert_equal "yrby/body", Y::Collaborative.sgid_purpose(:body)
    assert_equal @page, GlobalID::Locator.locate_signed(@page.collaborative_document(:body).grant, for: "yrby/body")
  end

  def test_tampered_and_missing_tokens_locate_nothing
    grant = @page.collaborative_document(:body).grant

    assert_nil Y::Collaborative.locate(grant.reverse, :body), "a tampered token locates nothing"
    assert_nil Y::Collaborative.locate(nil, :body)
    assert_nil GlobalID::Locator.locate_signed(grant, for: :something_else),
               "the token fails under any other purpose, even outside Y::Collaborative"
  end

  def test_expires_in_limits_the_grant_lifetime
    token = @page.collaborative_document(:body).grant(expires_in: 1.minute)

    assert_equal @page, Y::Collaborative.locate(token, :body)
    travel 2.minutes do
      assert_nil Y::Collaborative.locate(token, :body)
    end
  end

  def test_without_expires_in_the_default_lifetime_applies
    # Outside Rails GlobalID has no default expiry, so this token never
    # expires. The test checks that leaving out the option doesn't pass an
    # explicit nil.
    token = @page.collaborative_document(:body).grant

    travel 2.minutes do
      assert_equal @page, Y::Collaborative.locate(token, :body)
    end
  end

  def test_the_document_names_the_shipped_channel
    assert_equal "Y::DocumentChannel", @page.collaborative_document(:body).channel
  end

  def test_collaborative_sgid_still_signs_the_grant_and_warns
    token = assert_deprecated(/collaborative_document\(name\)\.grant/, Y.deprecator) do
      @page.collaborative_sgid(:body, expires_in: 1.minute)
    end

    assert_equal @page, Y::Collaborative.locate(token, :body)
  end

  def test_a_destroyed_record_locates_nothing
    grant = @page.collaborative_document(:body).grant
    @page.destroy!

    assert_nil Y::Collaborative.locate(grant, :body)
  end
end
