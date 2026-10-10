# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"
require "active_support/testing/time_helpers"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# JWT grants: the form loco-yrby (Rust) mints and verifies. They locate
# records like signed GlobalIDs do, scoped to one attribute, and a grant
# minted by either implementation verifies in the other.
class CollaborativeGrantTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  SECRET = "yrby-interop-grant-secret"

  # Minted by loco-yrby's GrantSigner (Rust) with SECRET for
  # "CollaborativeGrantTest::Page/fixture-page", "body", expiring in 2100.
  RUST_GRANT = [
    "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9",
    "eyJhdWQiOiJ5cmJ5Iiwic3ViIjoiQ29sbGFib3JhdGl2ZUdyYW50VGVzdDo6UGFnZS9maXh0dXJlLXBhZ2UiLCJuYW1lIjoiYm9keSIs" \
    "ImV4cCI6NDEwMjQ0NDgwMH0",
    "2TaNPq7R2ztEpawHztG2bEMASI3vILvp1sPYZ8ZOjm4"
  ].join(".")

  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  # Named by a public id instead of its primary key, as Loco models are.
  class PublicPage < ActiveRecord::Base
    self.table_name = "pages"
    include Y::Collaborative

    self.collaborative_public_id = :title
  end

  class NotCollaborative < ActiveRecord::Base
    self.table_name = "pages"
  end

  def setup
    @previous = [Y::Collaborative.grant_secret, Y::Collaborative.grant_format]
    Y::Collaborative.grant_secret = SECRET
    @page = Page.create!(title: "grant page")
  end

  def teardown
    Y::Collaborative.grant_secret, Y::Collaborative.grant_format = @previous
    Page.delete_all
  end

  def claims(token) = JSON.parse(Base64.urlsafe_decode64(token.split(".")[1]))

  def sign(claims, secret: SECRET, header: { "alg" => "HS256", "typ" => "JWT" })
    segments = [header, claims].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }
    body = segments.join(".")
    "#{body}.#{Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", secret, body), padding: false)}"
  end

  def test_grant_round_trips_for_its_own_attribute_only
    grant = @page.collaborative_grant(:body, expires_in: 5.minutes)

    assert_equal @page, Y::Collaborative.locate(grant, :body)
    assert_nil Y::Collaborative.locate(grant, :title), "a grant for :body opens no other attribute"
  end

  def test_grant_claims_are_the_documented_contract
    grant = @page.collaborative_grant(:body, expires_in: 5.minutes)
    payload = claims(grant)

    assert_equal "yrby", payload["aud"]
    assert_equal "CollaborativeGrantTest::Page/#{@page.id}", payload["sub"]
    assert_equal "body", payload["name"]
    assert_in_delta 5.minutes.from_now.to_i, payload["exp"], 2
  end

  def test_a_public_id_names_the_record
    page = PublicPage.find(@page.id)
    grant = page.collaborative_grant(:body, expires_in: 5.minutes)

    assert_equal "CollaborativeGrantTest::PublicPage/grant page", claims(grant)["sub"]
    assert_equal page, Y::Collaborative.locate(grant, :body)
  end

  def test_a_grant_minted_by_rust_verifies
    PublicPage.create!(title: "fixture-page")

    located = Y::Collaborative.locate(RUST_GRANT.sub("::Page/", "::PublicPage/"), :body)

    assert_nil located, "editing the subject breaks the signature"

    Page.create!(title: "fixture-page")

    assert_nil Y::Collaborative.locate(RUST_GRANT, :body),
               "Page names records by id, so the pid-style subject finds nothing"

    with_public_id(Page, :title) do
      assert_equal "fixture-page", Y::Collaborative.locate(RUST_GRANT, :body)&.title
    end
  end

  def test_expired_grants_locate_nothing
    grant = @page.collaborative_grant(:body, expires_in: 1.minute)

    travel 2.minutes do
      assert_nil Y::Collaborative.locate(grant, :body)
    end
  end

  def test_untrusted_tokens_locate_nothing
    subject = "CollaborativeGrantTest::Page/#{@page.id}"
    valid = { "aud" => "yrby", "sub" => subject, "name" => "body", "exp" => 1.hour.from_now.to_i }
    unsigned = [{ "alg" => "none" }, valid].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }

    {
      "another secret" => sign(valid, secret: "guess"),
      "no audience (a login token)" => sign(valid.except("aud")),
      "another audience" => sign(valid.merge("aud" => "api")),
      "no expiry" => sign(valid.except("exp")),
      "alg none" => "#{unsigned.join(".")}.",
      "another algorithm" => sign(valid, header: { "alg" => "HS512" }),
      "a model without Y::Collaborative" => sign(valid.merge("sub" => "CollaborativeGrantTest::NotCollaborative/#{@page.id}")),
      "a class that is not a model" => sign(valid.merge("sub" => "Kernel/1")),
      "an unknown class" => sign(valid.merge("sub" => "Nope/1")),
      "a malformed subject" => sign(valid.merge("sub" => "/#{@page.id}")),
      "garbage" => "a.b.c"
    }.each do |label, token|
      assert_nil Y::Collaborative.locate(token, :body), label
    end
    assert_equal @page, Y::Collaborative.locate(sign(valid), :body), "the control token locates"
  end

  def test_a_deleted_record_locates_nothing
    grant = @page.collaborative_grant(:body, expires_in: 5.minutes)
    @page.destroy

    assert_nil Y::Collaborative.locate(grant, :body)
  end

  def test_without_a_secret_jwt_grants_are_off
    grant = @page.collaborative_grant(:body, expires_in: 5.minutes)
    Y::Collaborative.grant_secret = nil

    assert_nil Y::Collaborative.locate(grant, :body)
    assert_raises(ArgumentError) { @page.collaborative_grant(:body) }
  end

  def test_signed_global_ids_still_locate
    assert_equal @page, Y::Collaborative.locate(@page.collaborative_sgid(:body), :body)
  end

  private

  def with_public_id(model, attribute)
    previous = model.collaborative_public_id
    model.collaborative_public_id = attribute
    yield
  ensure
    model.collaborative_public_id = previous
  end
end
