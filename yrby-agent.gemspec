# frozen_string_literal: true

require_relative "lib/yrby/agent/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-agent"
  spec.version = Yrby::Agent::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "AI agents that edit yrby documents alongside people, through RubyLLM"
  spec.description = "Y::Agent joins a yrby document as a collaborator and, when people's typing " \
                     "settles, hands what they changed to a model through RubyLLM, with tools that " \
                     "read the document and edit its blocks live."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-agent.rb",
    "lib/yrby/agent/**/*.rb",
    "lib/y/agent.rb",
    "lib/y/agent/**/*.rb",
    "LICENSE",
    "CHANGELOG-agent.md"
  ]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG-agent.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Y::Agent is a Y::Collaborator, in yrby-rails from the release after 0.8.0.
  # Raise this to that release when it ships.
  spec.add_dependency "yrby-rails", ">= 0.8"
  # Y::Agent's settings are RubyLLM::Agent's, new in ruby_llm 2.0.
  spec.add_dependency "ruby_llm", "~> 2.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
