# Layer 1 of the throttle stack: per-IP HTTP rate limits. See app/lib/limits.rb
# for every number and why it is what it is.
#
# Rack::Attack's counters live in this process's memory cache, which is correct
# here for the same reason the document store is: the site is one process. In
# front of several processes these counters would have to move to a shared cache
# (and, honestly, to the CDN).
class Rack::Attack
  cache.store = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)

  # Static files are served straight off disk by the app, and a docs page pulls
  # several. Counting them would throttle a single page load.
  ASSET = %r{\A/(assets|[^/]+\.(js|css|map|png|svg|ico|txt))}

  # The health check is polled by the platform, not by visitors.
  safelist("health check") { |req| req.path == "/up" }
  safelist("static files") { |req| ASSET.match?(req.path) }

  # Page requests. Everything that isn't the cable handshake.
  throttle("pages/ip", limit: Limits::PAGE_REQUESTS, period: Limits::PAGE_PERIOD) do |req|
    req.ip unless req.path.start_with?("/cable")
  end

  # The cable handshake is the expensive one: it upgrades to a WebSocket and
  # holds a connection. Stricter, and counted separately so a burst of reconnects
  # can't also lock the reader out of the docs.
  throttle("cable/ip", limit: Limits::CABLE_HANDSHAKES, period: Limits::CABLE_PERIOD) do |req|
    req.ip if req.path.start_with?("/cable")
  end

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
end

Rails.application.config.middleware.use Rack::Attack
