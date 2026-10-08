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
