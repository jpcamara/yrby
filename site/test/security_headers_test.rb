require "test_helper"

# The response security headers, checked on a real request through the stack.
class SecurityHeadersTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "a docs page has a CSP with a strict script-src" do
    get "/docs/getting-started"

    csp = response.headers["Content-Security-Policy"]

    assert_predicate csp, :present?, "every response must have a CSP"
    assert_includes csp, "script-src 'self'"
    assert_not_includes csp, "script-src 'self' 'unsafe-inline'",
                        "script-src must not allow inline scripts"
    assert_includes csp, "frame-ancestors 'none'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "base-uri 'self'"
    # The cable is same-origin ws/wss.
    assert_includes csp, "connect-src 'self' ws: wss:"
  end

  test "the CSP loads no images, media, or frames from data: or blob: URLs" do
    get "/demos/lexxy/room1"
    directives = response.headers["Content-Security-Policy"].split(";").to_h do |directive|
      name, *values = directive.split
      [name, values.join(" ")]
    end

    assert_equal "'self'", directives["img-src"], "img-src must not allow data: or blob:"
    assert_equal "'none'", directives["media-src"]
    assert_equal "'none'", directives["frame-src"]
    assert_equal "'self'", directives["form-action"]
    assert_equal "'none'", directives["object-src"]
    assert_no_match(/data:|blob:/, response.headers["Content-Security-Policy"])
  end

  test "the built Lexxy stylesheet has no data: URLs for the CSP to block" do
    css = Rails.root.join("public/lexxy.css")
    skip "run `cd frontend && bun run build` first" unless css.exist?

    assert_not_includes css.read, "data:", "frontend/build.mjs writes Lexxy's inline icons out as files"
    css.read.scan(%r{url\("/(lexxy-icon-\h+\.svg)"\)}).flatten.uniq.each do |icon|
      assert_predicate Rails.root.join("public", icon), :exist?
    end
  end

  test "style-src allows inline (syntect + editor styles) but only style-src" do
    get "/docs/getting-started"
    csp = response.headers["Content-Security-Policy"]

    assert_includes csp, "style-src 'self' 'unsafe-inline'"
  end

  test "the standard hardening headers are present" do
    get "/docs/getting-started"

    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "strict-origin-when-cross-origin", response.headers["Referrer-Policy"]
  end

  test "a demo page has a CSP too" do
    get "/demos/spreadsheet/room1"

    assert_predicate response.headers["Content-Security-Policy"], :present?
    assert_equal "DENY", response.headers["X-Frame-Options"]
  end

  test "no page over plain http sends HSTS" do
    # Test and development run without force_ssl, like a plain-http LAN box.
    # HSTS should only be sent once TLS is in place, so it must be absent here.
    get "/docs/getting-started"

    assert_nil response.headers["Strict-Transport-Security"]
  end
end
