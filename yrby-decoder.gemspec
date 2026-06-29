# frozen_string_literal: true

require_relative "lib/y/decoder/version"

Gem::Specification.new do |spec|
  spec.name = "yrby-decoder"
  spec.version = Y::Decoder::VERSION
  spec.authors = ["JP Camara"]
  spec.email = ["johnpcamara@gmail.com"]

  spec.summary = "Pure-Ruby plain-text reconstruction of a stored Yjs document, for search indexing and previews"
  spec.description = "yrby-decoder reads the text out of a stored Yjs CRDT state in pure Ruby — Lexical's " \
                     "Y.XmlText, plain Y.Text, or ProseMirror's Y.XmlFragment — on the native extension the core " \
                     "yrby gem already ships. No Node, no subprocess, no binary: ideal for search indexing and " \
                     "previews. Full-fidelity Lexical EditorState / HTML reconstruction is a separate, opt-in concern " \
                     "(the yrby-decode Bun binary)."
  spec.homepage = "https://github.com/jpcamara/yrby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/yrby-decoder.rb",
    "lib/y/decoder.rb",
    "lib/y/decoder/**/*.rb",
    "LICENSE",
    "README.md",
    "CHANGELOG-decoder.md"
  ]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG-decoder.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "base64", "~> 0.2"
  # Needs the Doc content readers (root_names / read_text / read_xml). Bump the
  # floor to the first published core release that ships them.
  spec.add_dependency "yrby", ">= 0.2.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
