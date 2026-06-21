# frozen_string_literal: true

require_relative "lib/yrb_lite/action_cable/version"

Gem::Specification.new do |spec|
  spec.name = "yrb-lite-actioncable"
  spec.version = YrbLite::ActionCable::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "ActionCable integration for yrb-lite: the y-websocket sync protocol and awareness over ActionCable/AnyCable"
  spec.description = "yrb-lite-actioncable adds a Rails ActionCable channel concern (YrbLite::ActionCable::Sync) on " \
                     "top of the yrb-lite y-crdt bindings: the full y-websocket sync protocol, awareness/presence, " \
                     "record-before-distribute auditing, and memory/store backends (AnyCable-ready), so a Rails app " \
                     "can be the collaboration server for Y.js editors with no Node sidecar."
  spec.homepage = "https://github.com/jpcamara/yrb-lite"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrb-lite-actioncable.rb",
    "lib/yrb_lite/action_cable.rb",
    "lib/yrb_lite/action_cable/**/*.rb",
    "LICENSE",
    "README.md",
    "CHANGELOG-actioncable.md"
  ]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG-actioncable.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "yrb-lite", ">= 0.1.0.beta5"
  # The concern references ActionCable (channels, streaming, broadcasting) and
  # ActiveSupport (Concern, JSON coder) constants directly. Rails apps already
  # bundle these, but declaring them makes use outside a full Rails bundle fail
  # at install time with a clear message instead of at runtime with a NameError.
  spec.add_dependency "actioncable", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
