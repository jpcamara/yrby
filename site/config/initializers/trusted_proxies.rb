# Real client IP behind Cloudflare (and any other trusted proxy).
#
# Rack::Attack throttles on `request.ip`, which ActionDispatch derives from the
# X-Forwarded-For chain. The catch: XFF is client-supplied and trivially
# spoofed, so ActionDispatch only walks it past hops it *trusts* — the first
# untrusted address from the right is the real client. Without Cloudflare's
# ranges in that trusted set, the address on every request is Cloudflare's edge,
# and the whole internet collapses into one throttle bucket.
#
# Setting `trusted_proxies` explicitly REPLACES Rails' defaults (it does not add
# to them — verified against ActionDispatch::RemoteIp), and that is deliberately
# used here: the list below trusts the Cloudflare edge and the container-internal
# hops, but NOT 192.168.0.0/16. That exclusion is the point. A LAN box's clients are
# on 192.168.x, and ActionDispatch strips trusted hops from the X-Forwarded-For
# chain and takes the rightmost address that remains — so if the LAN were
# trusted, a LAN client could set its own X-Forwarded-For and land as the
# rightmost-untrusted entry, spoofing another throttle bucket. Left untrusted,
# the LAN client's real address is the rightmost-untrusted entry and its forged
# header is ignored. Behind Cloudflare the same rule recovers the true client:
# Cloudflare's edge is stripped, the client it appended is what remains.
#
# What is trusted: Cloudflare's ranges, loopback (thrust talks to Falcon over
# it), and the Docker/container-internal ranges (10.0.0.0/8, 172.16.0.0/12) an
# intermediate hop might occupy. A deployment whose LAN or reverse proxy sits in
# 192.168.x would need to revisit this.
#
# Cloudflare ranges vendored from https://www.cloudflare.com/ips/ (ips-v4 +
# ips-v6), fetched 2026-08-31. They change rarely; refresh from that page.
require "ipaddr"

module TrustedProxies
  # Loopback and container-internal ranges — NOT 192.168.0.0/16 (see above).
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

  # The real client IP for a WebSocket connect, using these ranges as the trusted
  # set. This deliberately does NOT reuse ActionDispatch::RemoteIp / its GetIp.
  #
  # Two reasons. First, on the AnyCable connect path the RemoteIp middleware never
  # runs (the env is built by the RPC handler), so `request.remote_ip` there falls
  # back to Rack's default IP logic, which trusts every private range — including
  # the LAN this config excludes. Second, and worse for a cap, GetIp with spoof-
  # checking off will PREFER an X-Forwarded-For entry over an untrusted socket
  # peer: a client connecting straight to the edge (no trusted proxy in front)
  # could set any X-Forwarded-For and be counted as that address, a different one
  # per connection, sailing past the per-IP cap.
  #
  # So the rule here is strict and explicit: a forwarded address is honored only
  # when the IMMEDIATE peer (REMOTE_ADDR, set by anycable-go from the real socket)
  # is a proxy we trust to have set it. Behind Cloudflare/kamal/Fly that recovers
  # the true client (walk the chain from the right, skip trusted hops, take the
  # first untrusted). Connected to directly, the peer is the client (or an
  # untrusted hop) and its X-Forwarded-For is unverifiable, so the socket address
  # wins and the forged header is ignored.
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

  # Normalize an address token to a bare IP for the trusted-set check and the
  # throttle key. anycable-go's REMOTE_ADDR can carry a port, so strip it — two
  # connections from one client on different source ports must count as one IP.
  def self.ip_string(raw)
    s = raw.to_s.strip
    return "" if s.empty?
    return s[/\A\[([^\]]+)\]/, 1] || s.delete("[]") if s.start_with?("[") # [::1] / [::1]:443

    s.count(":") == 1 ? s.sub(/:\d+\z/, "") : s # IPv4:port has one colon; IPv6 has many
  end
end

Rails.application.config.action_dispatch.trusted_proxies = TrustedProxies::RANGES
