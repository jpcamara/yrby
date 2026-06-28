# frozen_string_literal: true

require_relative "lib/y/version"

Gem::Specification.new do |spec|
  spec.name = "y-ruby"
  spec.version = Y::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Thread-safe Ruby bindings for y-crdt (Y.js): documents, awareness, and the y-websocket sync protocol"
  spec.description = "y-ruby is a thread-safe Ruby binding over the Rust y-crdt (yrs) library: CRDT documents, " \
                     "awareness/presence, and the y-websocket sync protocol primitives, with the GVL released " \
                     "during native work so documents sync in parallel. The ActionCable/Rails integration lives " \
                     "in the companion y-ruby-actioncable gem."
  spec.homepage = "https://github.com/jpcamara/y-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  # The ActionCable layer (lib/y/action_cable*) ships in the separate
  # y-ruby-actioncable gem, so it's excluded from the core gem here.
  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rb,rs,toml}",
    "Cargo.toml",
    "LICENSE",
    "README.md",
    "CHANGELOG.md"
  ] - Dir["lib/y-ruby-actioncable.rb", "lib/y/action_cable.rb", "lib/y/action_cable/**/*"]

  spec.require_paths = ["lib"]
  spec.extensions = ["ext/y_ruby/extconf.rb"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "rb_sys", "~> 0.9"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
end
