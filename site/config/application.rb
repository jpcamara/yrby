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

# Only the storage concern from lexxy-realtime (the gem itself is require:
# false — its engine drags in Lexxy's Action Text wiring, which cannot boot
# without Action Text; see the Gemfile). The concern is self-contained: it
# capability-detects has_rich_text and, absent Action Text, materializes the
# collaborative document into the model's plain column via Y::Lexxy.
require "lexxy_realtime/collaborative"

# Plain require, not autoload: the Rack::Attack initializer reads these
# constants while the app is still booting, which is exactly when autoloading is
# off limits.
require_relative "limits"

module Site
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # Deny framing outright — the demos aren't meant to be embedded, and
    # ActiveDispatch::Response snapshots default_headers from a railtie
    # initializer, so this override has to happen here (the config phase) rather
    # than in an initializer, or it never reaches the response. CSP's
    # frame-ancestors 'none' (config/initializers/content_security_policy.rb) is
    # the modern equivalent; this is the legacy belt. nosniff and Referrer-Policy
    # keep Rails' defaults.
    config.action_dispatch.default_headers =
      config.action_dispatch.default_headers.merge("X-Frame-Options" => "DENY")

    # Every demo bundle is a plain file in public/, and the container serves its
    # own assets. There is no separate web server in front inside the machine.
    config.public_file_server.enabled = true

    # Action Cable does not serve the WebSocket here; the anycable-go embedded in
    # thrust does, and calls back over the HTTP RPC endpoint AnyCable mounts at
    # /_anycable. Unmounting Rails' own /cable makes that explicit: hitting the
    # Rails server directly can't reach a cable that has no server behind it.
    config.action_cable.mount_path = nil

    # What action_cable_meta_tag renders for the browser. thrust serves the
    # pages and the cable on one port, so this is same-origin and relative;
    # frontend/src/room.js resolves it to an absolute ws:// URL.
    config.action_cable.url = ENV.fetch("CABLE_URL", "/cable")

    # WebSocket origin allow-list, one source driving both halves of the cable.
    # The primary check is in the embedded anycable-go, which 403s a mismatched
    # handshake at the socket (ANYCABLE_ALLOWED_ORIGINS, derived from
    # ALLOWED_ORIGINS by the Dockerfile/boot script). This is the belt to that
    # suspenders: anycable-rails re-runs the check on the Connect RPC against the
    # list here, so a spoofed RPC that somehow bypassed the Go gate is still
    # refused in Ruby.
    #
    # Cross-site WebSocket hijacking is the risk it closes — without it, any page
    # anywhere can open a socket to this cable in a visitor's browser. ENV-driven
    # because the deploy host isn't knowable here: a LAN box is reached by IP over
    # http, prod by https://<domain>. ALLOWED_ORIGINS is a comma-separated list
    # of full origins (scheme://host[:port]); Rails matches the Origin header
    # against them exactly.
    #
    # Unset (dev, local e2e, a LAN box with no fixed hostname): permissive, so
    # the app works wherever it lands.
    allowed_origins = ENV["ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    if allowed_origins.any?
      config.action_cable.allowed_request_origins = allowed_origins
    else
      config.action_cable.disable_request_forgery_protection = true
    end

    config.generators.system_tests = nil
  end
end
