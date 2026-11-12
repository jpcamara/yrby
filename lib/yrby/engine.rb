# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition
require "global_id/railtie" # so signed grants work even when the app doesn't load Active Job
require "y/pg_yrby"

module Yrby
  # The Rails engine. Autoloads the gem's models (Y::Document,
  # Y::DocumentUpdate) from app/models. Rails adds app/assets/javascript to
  # the asset paths, so the import-map pins resolve without an initializer.
  class Engine < ::Rails::Engine
    initializer "yrby.collaborative" do
      ActiveSupport.on_load(:active_record) { include Y::Collaborative }
      ActiveSupport.on_load(:action_view) { include Y::Collaborative::Helper }
    end

    # ydoc columns (store: :pg_yrby) read as binary, like bytea.
    initializer "yrby.pg_yrby" do
      ActiveSupport.on_load(:active_record_postgresqladapter) { Y::PgYrby.register_type(self) }
    end

    initializer "yrby.deprecator" do |app|
      app.deprecators[:yrby] = Y.deprecator
    end
  end
end
