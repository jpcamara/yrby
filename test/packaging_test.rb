# frozen_string_literal: true

require "test_helper"

# Gemspec file-list regressions. The repo ships three gems; the core gem must
# not package the files of the other two — a frozen duplicate on the load path
# can shadow (or be shadowed by) the standalone gem and drift silently between
# releases. This is a packaging bug that no runtime test catches, so it's
# asserted here.
class PackagingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def load_spec(name)
    Dir.chdir(ROOT) { Gem::Specification.load(File.join(ROOT, name)) }
  end

  def test_core_gem_excludes_the_actioncable_and_decoder_gems_files
    files = load_spec("yrby.gemspec").files

    assert_empty files.grep(/action_cable|actioncable|yrby-rails|update_log/), "Rails-layer files ship in yrby-rails"
    assert_empty files.grep(/decoder/), "decoder files ship in yrby-decoder"
  end

  def test_core_gem_ships_its_own_essentials
    files = load_spec("yrby.gemspec").files

    %w[lib/y.rb lib/yrby.rb lib/y/version.rb ext/yrby/extconf.rb
       ext/yrby/src/lib.rs Cargo.toml Cargo.lock].each do |f|
      assert_includes files, f
    end
  end

  def test_no_gem_packages_tests_or_artifacts
    %w[yrby.gemspec yrby-rails.gemspec yrby-decoder.gemspec].each do |gemspec|
      files = load_spec(gemspec).files

      assert_empty files.grep(%r{^(test|bench|examples|pkg|target|tmp)/}),
                   "#{gemspec} must not package tests/benchmarks/artifacts"
    end
  end
end
