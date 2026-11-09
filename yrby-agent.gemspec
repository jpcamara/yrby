# frozen_string_literal: true

require_relative "lib/yrby/agent/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-agent"
  spec.version = Yrby::Agent::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Ruby processes and AI agents that edit yrby documents alongside people"
  spec.description = "Y::ActionCable::Client joins a yrby document over Action Cable the way a browser " \
                     "does. Y::Collaborator takes part in a document the way a person does. Y::Agent " \
                     "is a collaborator that hands what people changed to a model through RubyLLM, " \
                     "with tools that read the document and edit its blocks live."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-agent.rb",
    "lib/yrby/agent/**/*.rb",
    "lib/y/action_cable/client.rb",
    "lib/y/action_cable/client/**/*.rb",
    "lib/y/collaborator.rb",
    "lib/y/collaborator/**/*.rb",
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

  spec.add_dependency "async-websocket", ">= 0.30"
  # The client sends what Doc#edit returns, which is only the block's own
  # writes from 0.9.1 on.
  spec.add_dependency "yrby", ">= 0.9.1"
  # A collaborator joins with collaborative_document(name)'s grant and
  # channel, new in yrby-rails 0.8.0.
  spec.add_dependency "yrby-rails", ">= 0.8"
  # Y::Agent's settings are RubyLLM::Agent's.
  spec.add_dependency "ruby_llm", "~> 2.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
