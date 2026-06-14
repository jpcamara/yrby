# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "yrb-lite"
  spec.version = "0.1.0"
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Simple Ruby bindings for y-crdt via Rust"
  spec.description = "A minimal Ruby gem providing y-crdt document sync protocol support via Rust bindings, plus ProseMirror content extraction without JavaScript. Designed for ActionCable integration."
  spec.homepage = "https://github.com/jpcamara/yrb-lite"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rb,rs,toml}",
    "Cargo.toml",
    "LICENSE",
    "README.md"
  ]

  spec.require_paths = ["lib"]
  spec.extensions = ["ext/yrb_lite/extconf.rb"]

  spec.add_dependency "rb_sys", "~> 0.9"
  spec.add_dependency "base64" # Required for Ruby 3.4+

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "minitest", "~> 5.0"
end
