require "test_helper"

# The response security headers, checked on a real request through the stack.
class SecurityHeadersTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "a docs page carries the CSP with a strict script-src" do
    get "/docs/getting-started"

    csp = response.headers["Content-Security-Policy"]

    assert_predicate csp, :present?, "every response must carry a CSP"
    assert_includes csp, "script-src 'self'"
    assert_not_includes csp, "script-src 'self' 'unsafe-inline'",
                        "script-src must be strict — no inline scripts anywhere"
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

  test "a demo page carries the CSP too" do
    get "/demos/spreadsheet/room1"

    assert_predicate response.headers["Content-Security-Policy"], :present?
    assert_equal "DENY", response.headers["X-Frame-Options"]
  end

  test "no page over plain http sends HSTS" do
    # The test/dev stack runs without force_ssl, exactly like the plain-http Pi;
    # HSTS must be absent there (it is only correct once TLS is terminated).
    get "/docs/getting-started"

    assert_nil response.headers["Strict-Transport-Security"]
  end
end
