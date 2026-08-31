require_relative "boot"

require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

require "bundler"
Bundler.require(*Rails.groups)

# yrby-rails is `require: false` in the Gemfile. Requiring the gem loads its
# Rails engine, which autoloads Y::Document and Y::DocumentUpdate from
# app/models; those are Active Record classes and this app has no Active Record.
# The channel concern is independent of them, so require it directly.
require "y/action_cable"

# Plain require, not autoload: the Rack::Attack initializer reads these
# constants while the app is still booting, which is exactly when autoloading is
# off limits.
require_relative "limits"

module Site
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # Every demo bundle is a plain file in public/, and the container serves its
    # own assets. There is no separate web server in front inside the machine.
    config.public_file_server.enabled = true

    # Action Cable's worker pool runs channel callbacks. Every callback here is
    # CPU-bound CRDT work that releases the GVL, so a small pool keeps the
    # parallelism without letting a flood queue unbounded work.
    config.action_cable.worker_pool_size = 4

    # Action Cable rejects a handshake whose Origin isn't allow-listed. Rooms
    # are anonymous and hold no credentials, so origin is not a security
    # boundary here; it only stops another site pointing its visitors' browsers
    # at this cable. Set CABLE_ALLOWED_ORIGINS (comma separated) in a deploy to
    # turn it on. Unset, the check is off, so the app boots and works on any
    # hostname.
    allowed_origins = ENV.fetch("CABLE_ALLOWED_ORIGINS", nil)
    if allowed_origins
      config.action_cable.allowed_request_origins = allowed_origins.split(",").map(&:strip)
    else
      config.action_cable.disable_request_forgery_protection = true
    end

    config.generators.system_tests = nil
  end
end
