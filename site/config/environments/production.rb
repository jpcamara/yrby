require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Everything in public/ — the demo bundles and site.css, all built by bun —
  # is served as plain static files with an hour of cache, matching the docs
  # pages' own max-age. There is no asset pipeline; a deploy's new files are
  # picked up within the hour, or immediately once a CDN purge is wired up.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.hour.to_i}" }

  # Behind Fly's proxy, Kamal's proxy, or Cloudflare — all of which terminate TLS.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  config.log_tags = [:request_id]
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  # One process, so an in-memory cache is the only cache that makes sense. It
  # also backs Rack::Attack's counters.
  config.cache_store = :memory_store

  config.i18n.fallbacks = true
end
