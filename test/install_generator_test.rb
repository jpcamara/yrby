# frozen_string_literal: true

require "test_helper"
require "rails"
require "rails/generators"
require "rails/generators/test_case"
require "generators/yrby/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Yrby::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator-destination", __dir__)
  setup :prepare_destination

  def test_generates_the_channel_over_gem_owned_storage
    run_generator

    assert_file "app/channels/document_channel.rb" do |channel|
      assert_match(/include Y::ActionCable\b/, channel)
      assert_match("Y::Document.load_state(key)", channel)
      assert_match("Y::Document.append(key, update)", channel)
      assert_match(/def authorized\?/, channel)
      assert_match(/false/, channel, "authorization fails closed")
    end
    assert_no_file "app/models/yrby_document_update.rb" # models ship in the gem
  end

  def test_generates_the_storage_migration
    run_generator

    version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    assert_migration "db/migrate/create_yrby_tables.rb" do |migration|
      assert_match(/ActiveRecord::Migration\[#{Regexp.escape(version)}\]/, migration)
      assert_match(":yrby_documents", migration)
      assert_match("t.string :key, null: false, index: { unique: true }", migration)
      assert_match("t.references :record, polymorphic: true, null: true", migration)
      assert_match("materialized_at", migration)
      assert_match(":yrby_document_updates", migration)
      assert_match("t.references :document", migration)
      assert_match(/t\.binary :payload, null: false, limit: 16\.megabytes - 1/, migration)
    end
  end
end
