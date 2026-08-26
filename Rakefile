# frozen_string_literal: true

require "bundler"
require "rake/testtask"
require "rake/extensiontask"
require "rb_sys/extensiontask"

# This repo ships multiple gems (core `yrby` + `yrby-rails`), so the
# default bundler/gem_tasks can't auto-pick a gemspec. Scope build/release/install
# to the core gem; the pure-Ruby rails gem builds via `rake rails_gem:build`.
Bundler::GemHelper.install_tasks(name: "yrby")

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Build the yrby-rails gem into pkg/"
task "rails_gem:build" do
  require_relative "lib/yrby/rails/version"
  mkdir_p "pkg"
  sh "gem build yrby-rails.gemspec --output " \
     "pkg/yrby-rails-#{Yrby::Rails::VERSION}.gem"
end

desc "Build the yrby-forms gem into pkg/"
task "forms_gem:build" do
  require_relative "lib/yrby/forms/version"
  mkdir_p "pkg"
  sh "gem build yrby-forms.gemspec --output " \
     "pkg/yrby-forms-#{Yrby::Forms::VERSION}.gem"
end

namespace :release do
  desc "Print the release sequence for all packages (3 gems + 2 npm packages)"
  task :steps do
    require "json"
    require_relative "lib/y/version"
    require_relative "lib/yrby/rails/version"
    require_relative "lib/yrby/forms/version"
    core = Y::VERSION
    cable = Yrby::Rails::VERSION
    forms = Yrby::Forms::VERSION
    npm = JSON.parse(File.read("packages/client/package.json"))["version"]
    forms_npm = JSON.parse(File.read("packages/forms/package.json"))["version"]
    puts <<~STEPS
      This repo ships FIVE publishable packages, versioned independently. Release the
      gems together when the shared core API changes. JP runs the push steps
      (RubyGems MFA, npm auth, and the default-branch guard).

      1) yrby #{core}  — core gem, native extension; precompiled platform gems via CI
         a. bump lib/y/version.rb + CHANGELOG.md, then commit
         b. git tag v#{core} && git push origin main "v#{core}"
         c. the "Precompiled gems" workflow builds 8 platform gems + the source gem
         d. gh run download <run-id> --dir tmp/ ; cp tmp/**/*.gem pkg/
         e. for g in pkg/yrby-#{core}*.gem; do gem push "$g" || break; done   # 9 gems (gem push takes ONE at a time)

      2) yrby-rails #{cable}  — gem, pure Ruby; one gem, no precompilation
         a. bump lib/yrby/rails/version.rb + CHANGELOG-rails.md, commit
         b. rake rails_gem:build
         c. gem push pkg/yrby-rails-#{cable}.gem

      3) yrby-forms #{forms}  — gem, pure Ruby; one gem, no precompilation
         a. bump lib/yrby/forms/version.rb + CHANGELOG-forms.md, commit
         b. rake forms_gem:build
         c. gem push pkg/yrby-forms-#{forms}.gem

      4) yrby-client #{npm}  — npm package (client SDK: provider + sync engine + reliable delivery)
         a. bump packages/client/package.json version, commit
         b. cd packages/client && npm publish

      5) yrby-forms #{forms_npm}  — npm package (the collaborative form elements)
         a. bump packages/forms/package.json version, commit
         b. cd packages/forms && npm publish

      The dependent gems pin a minimum `yrby` (a floor, so they tolerate
      newer core releases); only raise it when they need a newer core API.
    STEPS
  end
end

# Passing the gemspec registers the cross-compilation tasks
# (`native:<platform> gem`) that the precompiled-gem build relies on.
GEMSPEC = Gem::Specification.load("yrby.gemspec")

RbSys::ExtensionTask.new("yrby", GEMSPEC) do |ext|
  ext.lib_dir = "lib/y"
end

task default: %i[compile test]

desc "Clean build artifacts"
task :clean do
  sh "cargo clean" if File.exist?("Cargo.toml")
  rm_rf "tmp"
  rm_rf "lib/y/yrby.bundle"
  rm_rf "lib/y/yrby.so"
end
