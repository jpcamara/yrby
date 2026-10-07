# Layer 1 of the throttles: per-IP HTTP rate limits. config/limits.rb has every
# number and the reasoning for it.
#
# This only covers pages. WebSocket traffic never reaches Rack. anycable-go,
# embedded in the thrust proxy, handles /cable itself and calls Rails over HTTP
# RPC. The cable's limits are in ApplicationCable::Connection (sockets per IP),
# ConnectionGuard, and RoomGuarded (frames per second and the rest), all of
# which run in Ruby on the RPC calls.
#
# Rack::Attack's counters live in this process's memory. That works because the
# site runs one process by default. With more workers, each one keeps its own
# counts (see "Why one process by default" in README.md).
class Rack::Attack
  cache.store = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)

  # Static files come straight off disk, and a docs page loads several, so they
  # don't count against the page throttle. The pattern matches the whole path:
  # the `/assets/` tree, or a root-level file with a static extension
  # (`/site.css`, `/tiptap.js`, `/og.png`, `/robots.txt`, `/sitemap.xml`). It's
  # anchored with `\A…\z` so a path like `/assetsjunk` or `/x.js/attack` can't
  # skip the throttle just by containing something that looks like an asset.
  ASSET = %r{\A/(?:assets/.+|[^/]+\.(?:js|mjs|css|map|png|svg|ico|webp|woff2?|txt|xml|json))\z}

  # The AnyCable RPC endpoint. Callers authenticate with a bearer derived from
  # ANYCABLE_SECRET, and the embedded Go server calls it directly over
  # loopback. It shouldn't be reachable from the internet, but thrust's public
  # proxy would forward it to Falcon like any other path, because the proxy and
  # the Go server both connect to Falcon's one port. Blocking the path outright
  # would block the real RPC too, so the bearer decides. The Go server always
  # sends it, and an outside client can't. Authenticated calls are safelisted
  # and never throttled, since every message on the cable goes through them,
  # tagged with each visitor's forwarded IP. Unauthenticated calls get a 404.
  RPC_PATH = "/_anycable".freeze

  class << self
    # The bearer the embedded anycable-go sends, built the same way as in
    # AnyCable::HTTRPC::Server (Bearer <http_rpc_secret>). Memoized. If the
    # secret can't be read, this returns nil and the blocklist lets requests
    # through. The RPC handler still answers them with its own 401, and the
    # cable keeps working.
    def rpc_bearer
      return @rpc_bearer if defined?(@rpc_bearer)

      token = AnyCable.config.http_rpc_secret || AnyCable.config.http_rpc_secret!
      @rpc_bearer = token ? "Bearer #{token}" : nil
    rescue StandardError
      @rpc_bearer = nil
    end

    def rpc_path?(req)
      req.path == RPC_PATH || req.path.start_with?("#{RPC_PATH}/")
    end

    def authenticated_rpc?(req)
      bearer = rpc_bearer
      return false unless bearer

      given = req.env["HTTP_AUTHORIZATION"].to_s
      ActiveSupport::SecurityUtils.secure_compare(given, bearer)
    end
  end

  safelist("health check") { |req| req.path == "/up" }
  safelist("static files") { |req| ASSET.match?(req.path) }
  # Authenticated RPC calls skip every throttle, so a busy cable isn't
  # rate-limited by the visitor IPs on its commands.
  safelist("anycable rpc") { |req| rpc_path?(req) && authenticated_rpc?(req) }

  # An unauthenticated request to the RPC path comes from outside. Block it with
  # a 404 before the RPC handler parses anything, so the endpoint doesn't look
  # like it exists. Authenticated calls are safelisted above, so this only
  # catches outside traffic.
  blocklist("public anycable rpc") { |req| rpc_path?(req) && !authenticated_rpc?(req) }

  throttle("pages/ip", limit: Limits::PAGE_REQUESTS, period: Limits::PAGE_PERIOD, &:ip)

  self.throttled_responder = lambda do |request|
    match = request.env["rack.attack.match_data"] || {}
    retry_after = (match[:period] || Limits::PAGE_PERIOD).to_i
    body = "Too many requests. This is a public demo with per-IP rate limits; " \
           "try again in #{retry_after} seconds.\n"

    [429,
     { "content-type" => "text/plain; charset=utf-8",
       "retry-after" => retry_after.to_s,
       "cache-control" => "no-store" },
     [body]]
  end

  # Return 404 for a blocked /_anycable request, so a scanner can't tell a
  # blocked internal endpoint from a missing one.
  self.blocklisted_responder = lambda do |_request|
    [404,
     { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" },
     ["Not found\n"]]
  end
end

Rails.application.config.middleware.use Rack::Attack
