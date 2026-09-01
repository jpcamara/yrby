# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition

module Yrby
  # The Rails engine. Autoloads the gem's models (Y::Document,
  # Y::DocumentUpdate) from app/models.
  class Engine < ::Rails::Engine
    initializer "yrby.collaborative" do
      ActiveSupport.on_load(:active_record) { include Y::Collaborative }
    end
  end
end
