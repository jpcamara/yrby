# frozen_string_literal: true

require "rails/engine"
require "action_dispatch" # Engine::Configuration references it at subclass definition

module Yrby
  # The Rails engine: autoloads the gem-owned models (Y::Document,
  # Y::DocumentUpdate) from app/models, the way Action Text owns
  # ActionText::RichText.
  class Engine < ::Rails::Engine
  end
end
