require "test_helper"

# Layer 1: per-IP HTTP throttling.
class RackAttackTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }
  teardown { Rack::Attack.cache.store.clear }

  test "page requests are throttled per IP with a clear 429" do
    Limits::PAGE_REQUESTS.times do
      get "/docs/getting-started"

      assert_response :success
    end

    get "/docs/getting-started"

    assert_response :too_many_requests
    assert_equal Limits::PAGE_PERIOD.to_s, response.headers["retry-after"]
    assert_equal "no-store", response.headers["cache-control"]
    assert_includes response.body, "Too many requests"
  end

  test "the cable handshake has its own, stricter throttle" do
    Limits::CABLE_HANDSHAKES.times do
      get "/cable"

      assert_response :not_found # not an upgrade request; the throttle is what matters
    end

    get "/cable"

    assert_response :too_many_requests
    assert_equal Limits::CABLE_PERIOD.to_s, response.headers["retry-after"]
  end

  test "cable and page throttles are counted separately" do
    Limits::CABLE_HANDSHAKES.times { get "/cable" }

    get "/cable"

    assert_response :too_many_requests

    get "/docs/getting-started"

    assert_response :success, "a cable flood must not lock a reader out of the docs"
  end

  test "static files and the health check are not counted" do
    (Limits::PAGE_REQUESTS + 5).times do
      get "/up"

      assert_response :success
    end

    (Limits::PAGE_REQUESTS + 5).times do
      get "/icon.svg"

      assert_response :success
    end

    get "/docs/getting-started"

    assert_response :success
  end

  test "the throttle is per address" do
    Limits::PAGE_REQUESTS.times { get "/docs/getting-started" }

    get "/docs/getting-started"

    assert_response :too_many_requests

    get "/docs/getting-started", env: { "REMOTE_ADDR" => "198.51.100.42" }

    assert_response :success
  end
end
