require "test_helper"

# The fail-closed production boot checks (config/initializers/production_boot_checks.rb).
# The initializer only fires under RAILS_ENV=production; the logic is factored
# into ProductionBootChecks so it can be exercised here directly.
class ProductionBootChecksTest < ActiveSupport::TestCase
  STRONG = ("a".."z").to_a.join + ("A".."F").to_a.join # 32 chars

  def problems(secret:, origins:)
    ProductionBootChecks.problems("ANYCABLE_SECRET" => secret, "ALLOWED_ORIGINS" => origins)
  end

  test "a strong secret and a named origin pass" do
    assert_empty problems(secret: STRONG, origins: "https://yrby.dev")
  end

  test "an unset secret fails" do
    assert_includes problems(secret: nil, origins: "https://yrby.dev").first, "ANYCABLE_SECRET is not set"
  end

  test "the committed development secret fails" do
    assert_includes problems(secret: "yrby-site-development-secret", origins: "https://yrby.dev").first,
                    "development default"
  end

  test "a short secret fails" do
    assert_includes problems(secret: "tooshort", origins: "https://yrby.dev").first, "too short"
  end

  test "an unset origin allow-list fails" do
    assert_includes problems(secret: STRONG, origins: nil), "ALLOWED_ORIGINS is not set"
  end

  test "a blank/comma-only origin list fails" do
    assert_includes problems(secret: STRONG, origins: " , "), "ALLOWED_ORIGINS is not set"
  end

  test "both problems are reported together" do
    assert_equal 2, problems(secret: nil, origins: nil).length
  end
end
