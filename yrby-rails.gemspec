# frozen_string_literal: true

require_relative "lib/yrby/rails/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-rails"
  spec.version = Yrby::Rails::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "The Rails integration for yrby: sync channel, document models, and install generator"
  spec.description = "The Rails integration for yrby (formerly yrby-actioncable): a y-websocket sync " \
                     "channel for Action Cable and AnyCable (include Y::ActionCable), engine-owned " \
                     "document storage with compaction (Y::Document, Y::DocumentUpdate), and an " \
                     "install generator. A Rails app serves Y.js editors with no Node sidecar."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  # The yrby-forms files are excluded the same way the core gem excludes
  # this gem's: they ship in yrby-forms only.
  spec.files = Dir[
    "lib/yrby-rails.rb",
    "lib/yrby/**/*.rb",
    "lib/y/action_cable.rb",
    "lib/y/action_cable/**/*.rb",
    "app/**/*.rb",
    "lib/generators/**/*",
    "LICENSE",
    "README.md",
    "CHANGELOG-rails.md"
  ] - Dir["lib/yrby/forms/**/*", "lib/generators/yrby_forms{,/**/*}"]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG-rails.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "railties", ">= 7.1"
  # 0.7.0's handle_sync_message serves full state, pending included; the
  # channel's serve path and the store contract both depend on it.
  spec.add_dependency "yrby", ">= 0.7.0"
  # The concern calls ActionCable.server directly, and railties doesn't
  # depend on actioncable, so declare it. activesupport comes along with
  # activerecord either way; listed because the gem uses it directly.
  spec.add_dependency "actioncable", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
