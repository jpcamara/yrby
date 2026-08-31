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

  # Static files are served straight off disk, and a docs page pulls several.
  # Counting them would throttle a single page load.
  ASSET = %r{\A/(assets|[^/]+\.(js|css|map|png|svg|ico|txt))}

  # The AnyCable RPC endpoint. Every WebSocket command arrives here from the
  # embedded Go server over localhost, so this path carries the cable's whole
  # message volume — throttling it by IP would throttle the site itself. It is
  # authenticated by the AnyCable secret and is not reachable from outside the
  # machine in a real deployment.
  RPC_PATH = "/_anycable".freeze

  safelist("health check") { |req| req.path == "/up" }
  safelist("static files") { |req| ASSET.match?(req.path) }
  safelist("anycable rpc") { |req| req.path.start_with?(RPC_PATH) }

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
end

Rails.application.config.middleware.use Rack::Attack
