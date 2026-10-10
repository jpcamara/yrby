# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition
require "global_id/railtie" # initialize signed grants even when the app does not load Active Job

module Yrby
  # The Rails engine. Autoloads the gem's models (Y::Document,
  # Y::DocumentUpdate) from app/models.
  class Engine < ::Rails::Engine
    # config.yrby.grant_secret: signs and verifies JWT grants, shared with a
    # Loco app (or any other) whose grants this app accepts.
    # config.yrby.grant_format: :jwt to render JWT grants instead of signed
    # GlobalIDs.
    config.yrby = ActiveSupport::OrderedOptions.new

    # After initialization, so the settings can come from config/application.rb
    # or from an app initializer, which runs after the engine's own.
    config.after_initialize do |app|
      Y::Collaborative.grant_secret = app.config.yrby.grant_secret if app.config.yrby.grant_secret
      Y::Collaborative.grant_format = app.config.yrby.grant_format if app.config.yrby.grant_format
    end

    initializer "yrby.collaborative" do
      ActiveSupport.on_load(:active_record) { include Y::Collaborative }
      ActiveSupport.on_load(:action_view) { include Y::Collaborative::Helper }
    end
  end
end
