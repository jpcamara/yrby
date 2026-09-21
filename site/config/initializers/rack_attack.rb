# Layer 1 of the throttle stack: per-IP HTTP rate limits. See config/limits.rb
# for every number and why it is what it is.
#
# This only covers pages. WebSocket traffic never reaches Rack: anycable-go,
# embedded in the thrust proxy, terminates /cable itself and calls back in over
# HTTP RPC. So the cable's own limits live where the cable does — in
# ApplicationCable::Connection (sockets per IP) and DocumentChannel (frames per
# second), both of which run in Ruby on every RPC call.
#
# Rack::Attack's counters live in this process's memory cache, which is correct
# here for the same reason the document store is: one worker, always.
class Rack::Attack
  cache.store = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)

  # Static files are served straight off disk, and a docs page pulls several, so
  # they are not counted against the page throttle. The match is ANCHORED to
  # real asset shapes: the `/assets/` tree, or a root-level file with a static
  # extension (`/site.css`, `/tiptap.js`, `/og.png`, `/robots.txt`,
  # `/sitemap.xml`). It is NOT a substring match — an earlier version was, and
  # `/assetsjunk` or `/x.js/attack` slipped an arbitrary path past the throttle
  # by merely containing an asset-ish segment. `\A…\z` anchoring closes that: the
  # whole path must be an asset path, not just contain one.
  ASSET = %r{\A/(?:assets/.+|[^/]+\.(?:js|mjs|css|map|png|svg|ico|webp|woff2?|txt|xml|json))\z}

  # The AnyCable RPC endpoint. It is authenticated by a bearer derived from
  # ANYCABLE_SECRET, and the embedded Go server reaches it directly over loopback
  # — it is NOT meant to be reachable from the public internet. thrust's public
  # proxy would otherwise forward it to Falcon like any other path (both the
  # proxy and the Go server land on Falcon's one port), so it can't simply be
  # dropped in Rails middleware without dropping the real RPC too. The
  # distinguisher is the bearer: the Go server always carries it, an outside
  # client can't. So an authenticated call is safelisted (never throttled — it
  # carries the cable's whole message volume, tagged with each visitor's
  # forwarded IP), and an unauthenticated one is blocked with a 404.
  RPC_PATH = "/_anycable".freeze

  class << self
    # The exact bearer the embedded anycable-go presents, mirrored from
    # AnyCable::HTTRPC::Server (Bearer <http_rpc_secret>). Memoized. If it can't
    # be determined we return nil and fail OPEN on the block (the RPC handler's
    # own 401 still guards it) rather than wedge the cable shut.
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
  # The real RPC, authenticated: skip every throttle so a busy cable isn't
  # rate-limited by the visitor IPs its commands carry.
  safelist("anycable rpc") { |req| rpc_path?(req) && authenticated_rpc?(req) }

  # An unauthenticated hit on the RPC path is a public probe/flood: block it at
  # the edge (before the RPC handler parses anything) with a 404, so the endpoint
  # isn't even advertised as present. Authenticated calls were already safelisted
  # above, so this only ever catches outside traffic.
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

  # Blocked /_anycable from outside is a 404, not the default 403 — the path
  # simply isn't public, and a scanner shouldn't be able to tell a blocked
  # internal endpoint from a missing one.
  self.blocklisted_responder = lambda do |_request|
    [404,
     { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" },
     ["Not found\n"]]
  end
end

Rails.application.config.middleware.use Rack::Attack
