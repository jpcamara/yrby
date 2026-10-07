require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # bun builds the demo bundles and site.css into public/, and the app serves
  # them as plain static files with an hour of cache, the same max-age as the
  # docs pages. There's no asset pipeline. Browsers and CDNs pick up a deploy's
  # new files within the hour, or right away with a CDN purge.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.hour.to_i}" }

  # Fly's proxy, Kamal's proxy, and Cloudflare all terminate TLS in front of
  # the app. FORCE_SSL=false runs production over plain http, for a LAN or
  # self-hosted box with no TLS in front, such as a Raspberry Pi on a home
  # network. The rest of the production settings (eager loading, no reloader,
  # quiet logs) suit a slow single-board machine too.
  unless ENV["FORCE_SSL"] == "false"
    config.assume_ssl = true
    config.force_ssl = true
    config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  end

  config.log_tags = [:request_id]
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  # The site runs one process by default, so it uses an in-memory cache.
  config.cache_store = :memory_store

  config.i18n.fallbacks = true
end
