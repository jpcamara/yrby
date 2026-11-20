# frozen_string_literal: true

require "test_helper"
require "rails"
require "rails/generators"
require "rails/generators/test_case"
require "generators/yrby/insert_only_log/insert_only_log_generator"

# The migration itself runs in the suite on Postgres (support/active_record).
class InsertOnlyLogGeneratorTest < Rails::Generators::TestCase
  tests Yrby::Generators::InsertOnlyLogGenerator
  destination File.expand_path("../tmp/generator-destination", __dir__)
  setup :prepare_destination

  def test_writes_the_migration
    run_generator

    version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    assert_migration "db/migrate/insert_only_y_document_updates.rb" do |migration|
      assert_match(/ActiveRecord::Migration\[#{Regexp.escape(version)}\]/, migration)
      assert_match("PARTITION BY LIST (slot)", migration)
      assert_match("ADD COLUMN folded pg_snapshot", migration)
    end
  end
end
