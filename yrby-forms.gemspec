# frozen_string_literal: true

require_relative "lib/yrby/forms/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-forms"
  spec.version = Yrby::Forms::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Collaborative form fields for Rails over yrby"
  spec.description = "Declare attributes with has_collaborative_fields and every open form for a record " \
                     "edits one yrby document. Selects, checkboxes, numbers, and dates are " \
                     "last-write-wins map entries. Text fields merge concurrent typing through Y.Text. " \
                     "The form helpers render yrby's <yrby-document> element and the yrby-forms npm " \
                     "package's <collaborative-field>, and the gem's channel writes each change to " \
                     "the record's columns."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-forms.rb",
    "lib/yrby/forms/**/*.rb",
    "lib/y/forms.rb",
    "lib/y/forms/**/*.rb",
    "app/channels/y/forms/**/*.rb",
    "app/assets/javascript/yrby-forms/**/*",
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

  # The document is read with Doc#read_map and Doc#read_text. 0.9.0 is the
  # floor yrby-rails 0.9 sets.
  spec.add_dependency "yrby", ">= 0.9.0"
  # has_collaborative_fields declares its document with
  # has_collaborative_document's channel: option, new in yrby-rails 0.9.0.
  spec.add_dependency "yrby-rails", ">= 0.9"

  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
