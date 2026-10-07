# Real client IP behind Cloudflare (and any other trusted proxy).
#
# Rack::Attack throttles on `request.ip`, which ActionDispatch works out from
# the X-Forwarded-For chain. Clients can put anything in X-Forwarded-For, so
# ActionDispatch only skips hops it trusts, and the first untrusted address from
# the right is the client. Without Cloudflare's ranges in the trusted list,
# every request's address would be a Cloudflare edge server, and every visitor
# would share one throttle bucket.
#
# Setting `trusted_proxies` replaces Rails' defaults and doesn't add to them
# (checked in ActionDispatch::RemoteIp). This list trusts the Cloudflare edge
# and container-internal hops, and leaves out 192.168.0.0/16. A LAN box's
# clients are on 192.168.x. ActionDispatch strips trusted hops from the
# X-Forwarded-For chain and takes the rightmost address left. If the LAN were
# trusted, a LAN client could set its own X-Forwarded-For, end up as that
# rightmost address, and pose as someone else for throttling. With the LAN
# untrusted, the client's real address is the rightmost untrusted entry, and
# its forged header is ignored. Behind Cloudflare the same rule finds the real
# client: the Cloudflare hop is stripped, and the address Cloudflare appended
# is what's left.
#
# The trusted list is Cloudflare's ranges, loopback (thrust talks to Falcon
# over it), and the Docker and container-internal ranges (10.0.0.0/8,
# 172.16.0.0/12) that an intermediate hop might use. A deployment with its LAN
# or reverse proxy on 192.168.x would need to change this.
#
# The Cloudflare ranges are copied from https://www.cloudflare.com/ips/ (ips-v4
# and ips-v6), fetched 2026-08-31. They rarely change. Refresh them from that
# page.
require "ipaddr"

module TrustedProxies
  # Loopback and container-internal ranges. 192.168.0.0/16 is left out (see
  # above).
  INTERNAL = %w[
    127.0.0.0/8
    ::1/128
    10.0.0.0/8
    172.16.0.0/12
  ].freeze

  CLOUDFLARE_V4 = %w[
    173.245.48.0/20
    103.21.244.0/22
    103.22.200.0/22
    103.31.4.0/22
    141.101.64.0/18
    108.162.192.0/18
    190.93.240.0/20
    188.114.96.0/20
    197.234.240.0/22
    198.41.128.0/17
    162.158.0.0/15
    104.16.0.0/13
    104.24.0.0/14
    172.64.0.0/13
    131.0.72.0/22
  ].freeze

  CLOUDFLARE_V6 = %w[
    2400:cb00::/32
    2606:4700::/32
    2803:f800::/32
    2405:b500::/32
    2405:8100::/32
    2a06:98c0::/29
    2c0f:f248::/32
  ].freeze

  RANGES = (INTERNAL + CLOUDFLARE_V4 + CLOUDFLARE_V6).map { |cidr| IPAddr.new(cidr) }.freeze

  # The real client IP for a WebSocket connect, using these ranges as the
  # trusted list. This doesn't use ActionDispatch::RemoteIp or its GetIp, for
  # two reasons.
  #
  # First, on the AnyCable connect path the RPC handler builds the env and the
  # RemoteIp middleware never runs. `request.remote_ip` falls back to Rack's
  # default IP logic, which trusts every private range, including the LAN this
  # file leaves out. Second, GetIp with spoof checking off prefers an
  # X-Forwarded-For entry over an untrusted socket peer. A client connecting
  # straight to the edge, with no trusted proxy in front, could set any
  # X-Forwarded-For, be counted as a different address on each connection, and
  # get around the per-IP cap.
  #
  # So this method uses a forwarded address only when the immediate peer
  # (REMOTE_ADDR, which anycable-go sets from the real socket) is a trusted
  # proxy. Behind Cloudflare, Kamal, or Fly, that finds the real client: walk
  # the chain from the right, skip trusted hops, and take the first untrusted
  # address. On a direct connection, the peer is the client or an untrusted hop,
  # and its X-Forwarded-For can't be verified, so the method uses the socket
  # address and ignores the header.
  def self.client_ip(request)
    remote_addr = ip_string(request.get_header("REMOTE_ADDR"))
    return remote_addr unless trusted?(remote_addr)

    forwarded = split_ips(request.get_header("HTTP_X_FORWARDED_FOR"))
    forwarded.reverse_each.find { |ip| !trusted?(ip) } || remote_addr
  end

  def self.trusted?(ip)
    addr = IPAddr.new(ip)
    RANGES.any? { |range| range.include?(addr) }
  rescue IPAddr::Error
    false
  end

  def self.split_ips(header)
    header.to_s.split(",").map { |part| ip_string(part) }.reject(&:empty?)
  end

  # Turns an address into a bare IP for the trusted-list check and the throttle
  # key. anycable-go's REMOTE_ADDR can include a port. Strip it, so two
  # connections from one client on different source ports count as one IP.
  def self.ip_string(raw)
    s = raw.to_s.strip
    return "" if s.empty?
    return s[/\A\[([^\]]+)\]/, 1] || s.delete("[]") if s.start_with?("[") # [::1] / [::1]:443

    s.count(":") == 1 ? s.sub(/:\d+\z/, "") : s # IPv4:port has one colon; IPv6 has many
  end
end

Rails.application.config.action_dispatch.trusted_proxies = TrustedProxies::RANGES
