require "test_helper"

# The real-client-IP derivation Rack::Attack throttles on. Drives the actual
# ActionDispatch::RemoteIp middleware with the app's configured trusted proxies,
# so this is what request.ip resolves to in production, not a reimplementation.
#
# ActionDispatch strips trusted hops from the X-Forwarded-For chain and takes
# the rightmost address that remains; every case below turns on which hops are
# trusted (config/initializers/trusted_proxies.rb).
class TrustedProxiesTest < ActiveSupport::TestCase
  CLOUDFLARE_IP = "104.16.1.1".freeze # inside 104.16.0.0/13
  CLIENT_IP = "203.0.113.7".freeze    # TEST-NET-3, a public client
  LAN_IP = "192.168.1.10".freeze      # a LAN client, deliberately untrusted

  # Resolve request.ip the way the running stack does: the RemoteIp middleware
  # built with the app's trusted_proxies, handed a peer and X-Forwarded-For.
  def resolved_ip(peer:, xff: nil)
    app = ->(env) { [200, {}, [ActionDispatch::Request.new(env).remote_ip]] }
    middleware = ActionDispatch::RemoteIp.new(app, false, TrustedProxies::RANGES)
    env = { "REMOTE_ADDR" => peer }
    env["HTTP_X_FORWARDED_FOR"] = xff if xff
    _, _, body = middleware.call(env)
    body.first
  end

  test "behind Cloudflare, the real client is recovered from X-Forwarded-For" do
    # Cloudflare appends the client to XFF and is the peer; trusting its range
    # strips the edge and leaves the client.
    assert_equal CLIENT_IP, resolved_ip(peer: CLOUDFLARE_IP, xff: "#{CLIENT_IP}, #{CLOUDFLARE_IP}")
  end

  test "a client cannot forge a hop to the right of itself behind Cloudflare" do
    # A forged entry can only be prepended (left); the trusted edge appends the
    # real socket address to the right, so the client is still rightmost-untrusted.
    assert_equal CLIENT_IP, resolved_ip(peer: CLOUDFLARE_IP, xff: "1.2.3.4, #{CLIENT_IP}, #{CLOUDFLARE_IP}")
  end

  test "on a LAN box (no Cloudflare) the LAN client is used, forged XFF ignored" do
    # kamal-proxy forwards from loopback and appends the LAN client; 192.168/16
    # is NOT trusted, so the LAN address is the rightmost-untrusted entry and a
    # client-prepended fake is ignored.
    assert_equal LAN_IP, resolved_ip(peer: "127.0.0.1", xff: "9.9.9.9, #{LAN_IP}")
    assert_equal LAN_IP, resolved_ip(peer: "127.0.0.1", xff: LAN_IP)
  end

  test "a Cloudflare edge address is never mistaken for the client" do
    # Only the client's forged header, ending in a Cloudflare IP, with the LAN
    # proxy appending the real client after it: the CF address is stripped.
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
