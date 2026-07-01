# frozen_string_literal: true

require_relative "lib/y/action_cable/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-actioncable"
  spec.version = Y::ActionCable::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "ActionCable integration for yrby: the y-websocket sync protocol and awareness over ActionCable/AnyCable"
  spec.description = "yrby-actioncable adds a Rails ActionCable channel concern (Y::ActionCable::Sync) on " \
                     "top of the yrby y-crdt bindings: the full y-websocket sync protocol, awareness/presence, " \
                     "record-before-distribute auditing, and memory/store backends (AnyCable-ready), so a Rails app " \
                     "can be the collaboration server for Y.js editors with no Node sidecar."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-actioncable.rb",
    "lib/y/action_cable.rb",
    "lib/y/action_cable/**/*.rb",
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
  # Floor raised to 0.3.0, whose handle_sync_message answers SyncStep1 with
  # integrated-only (gap-free) state. The channel serves the sync response through
  # that method, so the floor makes gap-free serving self-enforcing rather than
  # dependent on the app updating the core gem. (0.2.3 similarly made
  # update_advances? exact for delete-bearing updates.)
  spec.add_dependency "yrby", ">= 0.3.0"
  # The concern references ActionCable (channels, streaming, broadcasting) and
  # ActiveSupport (Concern, JSON coder) constants directly. Rails apps already
  # bundle these, but declaring them makes use outside a full Rails bundle fail
  # at install time with a clear message instead of at runtime with a NameError.
  spec.add_dependency "actioncable", ">= 7.0"
  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
