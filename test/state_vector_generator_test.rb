# frozen_string_literal: true

require "test_helper"
require "rails"
require "rails/generators"
require "rails/generators/test_case"
require "generators/yrby/state_vector/state_vector_generator"

class StateVectorGeneratorTest < Rails::Generators::TestCase
  tests Yrby::Generators::StateVectorGenerator
  destination File.expand_path("../tmp/generator-destination", __dir__)
  setup :prepare_destination

  def test_adds_the_column_to_existing_tables
    run_generator

    version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    assert_migration "db/migrate/add_state_vector_to_y_documents.rb" do |migration|
      assert_match(/ActiveRecord::Migration\[#{Regexp.escape(version)}\]/, migration)
      assert_match("add_column :y_documents, :state_vector, :binary", migration)
    end
  end
end
