require "test_helper"

# How the app finds the client IP that Rack::Attack throttles on. These tests
# run the real ActionDispatch::RemoteIp middleware with the app's trusted
# proxies, so they check the same request.ip production uses.
#
# ActionDispatch removes trusted hops from the X-Forwarded-For chain and takes
# the rightmost address left. Each case below depends on which hops are
# trusted (config/initializers/trusted_proxies.rb).
class TrustedProxiesTest < ActiveSupport::TestCase
  CLOUDFLARE_IP = "104.16.1.1".freeze # inside 104.16.0.0/13
  CLIENT_IP = "203.0.113.7".freeze    # TEST-NET-3, a public client
  LAN_IP = "192.168.1.10".freeze      # a LAN client, not trusted on purpose

  # Works out request.ip the way the app does, by running the RemoteIp
  # middleware with the app's trusted proxies, a peer, and an X-Forwarded-For.
  def resolved_ip(peer:, xff: nil)
    app = ->(env) { [200, {}, [ActionDispatch::Request.new(env).remote_ip]] }
    middleware = ActionDispatch::RemoteIp.new(app, false, TrustedProxies::RANGES)
    env = { "REMOTE_ADDR" => peer }
    env["HTTP_X_FORWARDED_FOR"] = xff if xff
    _, _, body = middleware.call(env)
    body.first
  end

  test "behind Cloudflare, the real client is recovered from X-Forwarded-For" do
    # Cloudflare is the peer and appends the client to XFF. Its range is
    # trusted, so the edge address is removed and the client is left.
    assert_equal CLIENT_IP, resolved_ip(peer: CLOUDFLARE_IP, xff: "#{CLIENT_IP}, #{CLOUDFLARE_IP}")
  end

  test "a forged hop from a client behind Cloudflare is ignored" do
    # A client can only add fake entries on the left. Cloudflare appends the real
    # address on the right, so the client is still the rightmost untrusted one.
    assert_equal CLIENT_IP, resolved_ip(peer: CLOUDFLARE_IP, xff: "1.2.3.4, #{CLIENT_IP}, #{CLOUDFLARE_IP}")
  end

  test "on a LAN box without Cloudflare the LAN client is used and a forged XFF is ignored" do
    # kamal-proxy forwards from loopback and appends the LAN client. 192.168/16
    # isn't trusted, so the LAN address is the rightmost untrusted entry and a
    # fake entry the client added is ignored.
    assert_equal LAN_IP, resolved_ip(peer: "127.0.0.1", xff: "9.9.9.9, #{LAN_IP}")
    assert_equal LAN_IP, resolved_ip(peer: "127.0.0.1", xff: LAN_IP)
  end

  test "a Cloudflare edge address is not taken as the client" do
    # The client sends a forged header ending in a Cloudflare IP, and the LAN
    # proxy appends the real client after it. The Cloudflare address is removed.
    assert_equal LAN_IP, resolved_ip(peer: "127.0.0.1", xff: "#{CLOUDFLARE_IP}, #{LAN_IP}")
  end

  test "Cloudflare's published ranges and the internal ranges are present" do
    assert_includes TrustedProxies::RANGES, IPAddr.new("104.16.0.0/13")
    assert_includes TrustedProxies::RANGES, IPAddr.new("2606:4700::/32")
    assert_includes TrustedProxies::RANGES, IPAddr.new("10.0.0.0/8")
    assert_not_includes TrustedProxies::RANGES, IPAddr.new("192.168.0.0/16")
    assert(TrustedProxies::RANGES.all?(IPAddr))
  end
end
