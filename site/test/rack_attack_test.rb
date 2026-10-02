require "test_helper"

# Layer 1: per-IP HTTP throttling.
class RackAttackTest < ActionDispatch::IntegrationTest
  # Rack::Attack counts in fixed windows keyed by the clock, so a run that
  # straddles a period boundary loses its count and the request that should be
  # the one over the limit comes back unthrottled. Freeze the clock: these
  # tests are about the rule, not about when the window rolls over.
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
    # thrust would forward /_anycable to Falcon like any other path; an outside
    # client that can't present the bearer must not reach the RPC endpoint.
    post "/_anycable/connect"

    assert_response :not_found
    assert_equal "Not found\n", response.body
  end

  test "the authenticated RPC endpoint is reached and never throttled" do
    # Every WebSocket command arrives here from the embedded Go server carrying
    # the bearer, so this path carries the cable's whole message volume.
    # Throttling it by IP would throttle the site itself, so it is safelisted,
    # and a flood of it must not consume a visitor's page budget either.
    headers = { "Authorization" => Rack::Attack.rpc_bearer }
    (Limits::PAGE_REQUESTS + 5).times { post "/_anycable/connect", headers: headers }

    # It reached the RPC handler (empty body => 422), not the block (404).
    assert_response :unprocessable_entity

    get "/docs/getting-started"

    assert_response :success
  end

  test "an asset-lookalike path is still throttled" do
    # The anchored ASSET match must not let /assetsjunk or /x.js/attack past the
    # throttle just for containing an asset-ish segment.
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

  test "the discoverability endpoints are served and not throttled" do
    # The redesign's SEO routes must keep working past the page limit (they are
    # cacheable meta, matched by the anchored asset rule).
    %w[/robots.txt /sitemap.xml /llms.txt /llms-full.txt].each do |path|
      (Limits::PAGE_REQUESTS + 2).times { get path }

      assert_response :success, "#{path} should stay served"
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
