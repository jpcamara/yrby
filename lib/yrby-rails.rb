# frozen_string_literal: true

# Entry point matching the gem name, so `Bundler.require` loads it automatically.
require "yrby/version"
require "y/action_cable"
require "yrby/engine" if defined?(Rails::Engine)
