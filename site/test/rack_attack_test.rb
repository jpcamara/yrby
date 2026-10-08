require "test_helper"

# Layer 1: per-IP HTTP throttling.
class RackAttackTest < ActionDispatch::IntegrationTest
  # Rack::Attack counts in fixed time windows. If a test run crosses into a
  # new window, the count resets and the request that should be over the limit
  # gets through. Freezing the clock keeps every request in one window.
  setup do
    Rack::Attack.cache.store.clear
    freeze_time
  end

  teardown do
    travel_back
    Rack::Attack.cache.store.clear
  end

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

  test "an unauthenticated hit on the RPC path is blocked with a 404" do
    # thrust forwards /_anycable to Falcon like any other path, so an outside
    # client without the bearer token must be blocked here.
    post "/_anycable/connect"

    assert_response :not_found
    assert_equal "Not found\n", response.body
  end

  test "the authenticated RPC endpoint is reachable and not throttled" do
    # The embedded Go server sends every WebSocket command here with the bearer
    # token, so all cable traffic goes through this path. Throttling it by IP
    # would throttle the site itself, so it's safelisted. Heavy RPC traffic
    # also must not use up a visitor's page budget.
    headers = { "Authorization" => Rack::Attack.rpc_bearer }
    (Limits::PAGE_REQUESTS + 5).times { post "/_anycable/connect", headers: headers }

    # The RPC handler answered (an empty body gets 422). A block would be 404.
    assert_response :unprocessable_entity

    get "/docs/getting-started"

    assert_response :success
  end

  test "an asset-lookalike path is still throttled" do
    # The ASSET pattern is anchored, so /assetsjunk and /x.js/attack are still
    # throttled even though they look like asset paths.
    %w[/assetsjunk /x.js/attack].each do |path|
      Rack::Attack.cache.store.clear
      Limits::PAGE_REQUESTS.times { get path }
      get path

      assert_response :too_many_requests, "#{path} should be throttled, not safelisted"
    end
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

  test "robots, sitemap, and llms files are not throttled" do
    # These routes match the anchored asset rule, so they keep working past the
    # page limit.
    %w[/robots.txt /sitemap.xml /llms.txt /llms-full.txt].each do |path|
      (Limits::PAGE_REQUESTS + 2).times { get path }

      assert_response :success, "#{path} should still be served"
    end
  end

  test "the throttle is per address" do
    Limits::PAGE_REQUESTS.times { get "/docs/getting-started" }

    get "/docs/getting-started"

    assert_response :too_many_requests

    get "/docs/getting-started", env: { "REMOTE_ADDR" => "198.51.100.42" }

    assert_response :success
  end
end
