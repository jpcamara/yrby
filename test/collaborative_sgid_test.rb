# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# The signed handshake for record-backed documents: a page mints
# collaborative_sgid(:attr), a channel trades it back through
# Y::Collaborative.locate, and the purpose scoping is what keeps a token for
# one attribute from opening any other.
class CollaborativeSgidTest < Minitest::Test
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

  def test_a_destroyed_record_locates_nothing
    sgid = @page.collaborative_sgid(:body)
    @page.destroy!

    assert_nil Y::Collaborative.locate(sgid, :body)
  end
end
