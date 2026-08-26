# frozen_string_literal: true

require_relative "lib/yrby/forms/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-forms"
  spec.version = Yrby::Forms::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Collaborative form fields for Rails over yrby: model macro, form helpers, and channel generator"
  spec.description = "Collaborative form fields for Rails over yrby. Declare attributes with " \
                     "has_collaborative_fields and every open form shares one CRDT document per record: " \
                     "last-write-wins fields in a shared map, character-merge text fields in Y.Text shares. " \
                     "Ships form helpers rendering the <collaborative-form>/<collaborative-field> elements " \
                     "(the yrby-forms npm package), a materializer writing values back to the columns, and " \
                     "an install generator for the sync channel."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-forms.rb",
    "lib/yrby/forms/**/*.rb",
    "lib/y/forms.rb",
    "lib/y/forms/**/*.rb",
    "lib/generators/yrby_forms/**/*",
    "LICENSE",
    "README-forms.md",
    "CHANGELOG-forms.md"
  ]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG-forms.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/README-forms.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # 0.7.1 is the current core release; the materializer reads documents
  # through Y::Doc#read_map and #read_text.
  spec.add_dependency "yrby", ">= 0.7.1"
  # 0.6.1 is the current Rails-layer release; storage and the sync channel
  # concern come from it (Y::Document, Y::EncryptedDocument, Y::ActionCable).
  spec.add_dependency "yrby-rails", ">= 0.6.1"

  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  # The form helper mints signed GlobalIDs; the generated channel locates
  # records through them.
  spec.add_dependency "globalid", ">= 1.0"
  spec.add_dependency "railties", ">= 7.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
