# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# Tests for the signed token behind record-backed documents. A page renders
# collaborative_sgid(:attr), and a channel looks the record up with
# Y::Collaborative.locate. The token's purpose names the attribute, so a token
# for one attribute can't open another.
class CollaborativeSgidTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  def setup
    @page = Page.create!(title: "sgid page")
  end

  def teardown
    Page.delete_all
  end

  def test_sgid_round_trips_for_its_own_attribute_only
    sgid = @page.collaborative_sgid(:body)

    assert_equal @page, Y::Collaborative.locate(sgid, :body)
    assert_nil Y::Collaborative.locate(sgid, :other_field),
               "a :body token must not locate the record for another attribute"
  end

  def test_sgid_purpose_names_the_attribute
    assert_equal "yrby/body", Y::Collaborative.sgid_purpose(:body)
    assert_equal @page, GlobalID::Locator.locate_signed(@page.collaborative_sgid(:body), for: "yrby/body")
  end

  def test_tampered_and_missing_tokens_locate_nothing
    sgid = @page.collaborative_sgid(:body)

    assert_nil Y::Collaborative.locate(sgid.reverse, :body), "a tampered token locates nothing"
    assert_nil Y::Collaborative.locate(nil, :body)
    assert_nil GlobalID::Locator.locate_signed(sgid, for: :something_else),
               "the token fails under any other purpose, even outside Y::Collaborative"
  end

  def test_expires_in_limits_the_grant_lifetime
    token = @page.collaborative_sgid(:body, expires_in: 1.minute)

    assert_equal @page, Y::Collaborative.locate(token, :body)
    travel 2.minutes do
      assert_nil Y::Collaborative.locate(token, :body)
    end
  end

  def test_without_expires_in_the_default_lifetime_applies
    # Outside Rails GlobalID has no default expiry, so this token never
    # expires. The test checks that leaving out the option doesn't pass an
    # explicit nil.
    token = @page.collaborative_sgid(:body)

    travel 2.minutes do
      assert_equal @page, Y::Collaborative.locate(token, :body)
    end
  end

  def test_a_destroyed_record_locates_nothing
    sgid = @page.collaborative_sgid(:body)
    @page.destroy!

    assert_nil Y::Collaborative.locate(sgid, :body)
  end
end
