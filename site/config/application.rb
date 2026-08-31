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

    # Action Cable does not serve the WebSocket here; the anycable-go embedded in
    # thrust does, and calls back over the HTTP RPC endpoint AnyCable mounts at
    # /_anycable. Unmounting Rails' own /cable makes that explicit: hitting the
    # Rails server directly can't reach a cable that has no server behind it.
    config.action_cable.mount_path = nil

    # What action_cable_meta_tag renders for the browser. thrust serves the
    # pages and the cable on one port, so this is same-origin and relative;
    # frontend/src/room.js resolves it to an absolute ws:// URL.
    config.action_cable.url = ENV.fetch("CABLE_URL", "/cable")

    # The origin check runs in anycable-go, not here (ANYCABLE_ALLOWED_ORIGINS).
    # Rooms are anonymous and hold no credentials, so origin is not a security
    # boundary; it only stops another site pointing its visitors' browsers at
    # this cable. Left unset, any origin is accepted, so the app works on
    # whatever hostname it is deployed to.

    config.generators.system_tests = nil
  end
end
