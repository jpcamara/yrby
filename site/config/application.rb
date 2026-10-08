require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

require "bundler"
Bundler.require(*Rails.groups)

# Load lexxy-realtime without its engine. See config/lexxy_realtime.rb.
require_relative "lexxy_realtime"

# A plain require, because the Rack::Attack initializer reads these constants
# while the app is still booting, before autoloading is available.
require_relative "limits"

module Site
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # LexxyRealtime::DocumentChannel, which NoteChannel extends. The gem's
    # engine would add this directory, and this app doesn't load the engine.
    config.eager_load_paths << File.join(Gem.loaded_specs.fetch("lexxy-realtime").full_gem_path, "app/channels")

    # Deny all framing, since the demos aren't meant to be embedded.
    # ActionDispatch::Response copies default_headers in a railtie initializer,
    # so this has to be set here in the config phase. Set in an initializer, it
    # would never reach the response. CSP's frame-ancestors 'none'
    # (config/initializers/content_security_policy.rb) does the same for modern
    # browsers, and this header covers older ones. nosniff and Referrer-Policy
    # keep Rails' defaults.
    config.action_dispatch.default_headers =
      config.action_dispatch.default_headers.merge("X-Frame-Options" => "DENY")

    # Every demo bundle is a plain file in public/, and the app serves its own
    # assets. There's no separate web server in front of it on the machine.
    config.public_file_server.enabled = true

    # Action Cable doesn't serve the WebSocket here. The anycable-go embedded in
    # thrust does, and it calls Rails through the HTTP RPC endpoint AnyCable
    # mounts at /_anycable. Rails' own /cable is unmounted, so a request that
    # goes straight to the Rails server can't open a cable with no server
    # behind it.
    config.action_cable.mount_path = nil

    # The URL action_cable_meta_tag renders for the browser. thrust serves the
    # pages and the cable on one port, so this is a relative, same-origin path.
    # frontend/src/room.js resolves it to an absolute ws:// URL.
    config.action_cable.url = ENV.fetch("CABLE_URL", "/cable")

    # Allowed WebSocket origins. One value configures both halves of the cable.
    # The embedded anycable-go checks first and returns 403 for a handshake
    # from another origin (ANYCABLE_ALLOWED_ORIGINS, which bin/docker-entrypoint
    # and frontend/boot_server.sh build from ALLOWED_ORIGINS). anycable-rails
    # then checks again on the Connect RPC against this list, so Ruby still
    # refuses a spoofed RPC that got past the Go check.
    #
    # Without this list, any page on the internet could open a socket to this
    # cable from a visitor's browser (cross-site WebSocket hijacking). It comes
    # from ENV because the host differs per deploy: a LAN box is reached by IP
    # over http, production by https://<domain>. ALLOWED_ORIGINS is a
    # comma-separated list of full origins (scheme://host[:port]), and Rails
    # matches the Origin header against them exactly.
    #
    # When it's unset (development, local e2e, a LAN box with no fixed
    # hostname), any origin is allowed so the app runs anywhere.
    allowed_origins = ENV["ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    if allowed_origins.any?
      config.action_cable.allowed_request_origins = allowed_origins
    else
      config.action_cable.disable_request_forgery_protection = true
    end

    config.generators.system_tests = nil
  end
end
