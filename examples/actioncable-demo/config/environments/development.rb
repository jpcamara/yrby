require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Change to :null_store to avoid any caching.
  config.cache_store = :memory_store

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  config.action_cable.disable_request_forgery_protection = true
  config.action_cable.worker_pool_size = ENV.fetch("CABLE_WORKERS", 4).to_i
  # Under AnyCable, point the browser at anycable-go (e.g.
  # CABLE_URL=ws://localhost:8080/cable); action_cable_meta_tag emits it.
  config.action_cable.url = ENV["CABLE_URL"] if ENV["CABLE_URL"].present?
  config.action_cable.allowed_request_origins = [/.*/]
  # Schema is created out-of-band (see README); skip the migration-version
  # checks (their schema-dump path hits a broken native `date` on this box).
  config.active_record.migration_error = false
  config.active_record.dump_schema_after_migration = false

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
