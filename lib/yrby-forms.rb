# frozen_string_literal: true

# Entry point matching the gem name, so `Bundler.require` loads it automatically.
require "yrby/forms/version"
require "y/forms"
require "y/forms/engine" if defined?(Rails::Engine)
