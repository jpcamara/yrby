# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "yrb-lite"
  spec.version = "0.1.0"
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Thread-safe Ruby bindings for y-crdt (Y.js) with the y-websocket sync protocol for ActionCable"
  spec.description = "yrb-lite is a thread-safe Ruby binding over the Rust y-crdt (yrs) library plus an " \
                     "ActionCable concern implementing the full y-websocket sync protocol and awareness. It " \
                     "lets a Rails app be the collaboration server for Y.js editors (Tiptap, ProseMirror, " \
                     "BlockNote) with no Node sidecar."
  spec.homepage = "https://github.com/jpcamara/yrb-lite"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rb,rs,toml}",
    "Cargo.toml",
    "LICENSE",
    "README.md",
    "CHANGELOG.md"
  ]

  spec.require_paths = ["lib"]
  spec.extensions = ["ext/yrb_lite/extconf.rb"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # base64 stopped being a default gem in Ruby 3.4, so depend on it explicitly.
  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "rb_sys", "~> 0.9"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
end
