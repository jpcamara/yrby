# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# The signed token for record-backed documents. A page mints
# collaborative_sgid(:attr), a channel trades it back through
# Y::Collaborative.locate, and the purpose scope keeps a token for one
# attribute from opening any other.
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
               "a token minted for :body must not locate through another attribute's purpose"
  end

  def test_sgid_purpose_is_the_documented_contract
    assert_equal "yrby/body", Y::Collaborative.sgid_purpose(:body)
    assert_equal @page, GlobalID::Locator.locate_signed(@page.collaborative_sgid(:body), for: "yrby/body")
  end

  def test_tampered_and_missing_tokens_locate_nothing
    sgid = @page.collaborative_sgid(:body)

    assert_nil Y::Collaborative.locate(sgid.reverse, :body), "a tampered token verifies as nothing"
    assert_nil Y::Collaborative.locate(nil, :body)
    assert_nil GlobalID::Locator.locate_signed(sgid, for: :something_else),
               "the raw token is purpose-scoped for any other consumer too"
  end

  def test_expires_in_bounds_the_grant
    token = @page.collaborative_sgid(:body, expires_in: 1.minute)

    assert_equal @page, Y::Collaborative.locate(token, :body)
    travel 2.minutes do
      assert_nil Y::Collaborative.locate(token, :body)
    end
  end

  def test_without_expires_in_the_default_lifetime_applies
    # Outside Rails, GlobalID sets no default, so the token has no expiry. The
    # point is that omitting the option does not pass an explicit nil through.
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
