# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/yrby/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Yrby::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator-destination", __dir__)
  setup :prepare_destination

  def test_generates_the_channel_wired_to_the_store
    run_generator

    assert_file "app/channels/document_channel.rb" do |channel|
      assert_match(/include Y::ActionCable::Sync/, channel)
      assert_match(/on_load { \|key\| YrbyDocumentStore\.load\(key\) }/, channel)
      assert_match(/on_change { \|key, update\| YrbyDocumentStore\.append\(key, update\) }/, channel)
      assert_match(/sync_subscribed\(params\[:id\]\)/, channel)
      assert_match(/sync_receive\(data, params\[:id\]\)/, channel)
      assert_match(/return reject unless authorized\?\(params\[:id\]\)/, channel,
                   "the channel must fail closed until the app authorizes access")
    end
  end

  def test_generates_the_store_and_model
    run_generator

    assert_file "app/models/yrby_document_update.rb", /class YrbyDocumentUpdate < ApplicationRecord/
    assert_file "app/models/yrby_document_store.rb" do |store|
      assert_match(/def load\(key\)/, store)
      assert_match(/def append\(key, update\)/, store)
      assert_match(/def compact!\(key\)/, store)
      assert_match(/compacted_state_update/, store)
    end
  end

  def test_generates_a_migration_stamped_with_the_active_record_version
    run_generator

    version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    assert_migration "db/migrate/create_yrby_document_updates.rb" do |migration|
      assert_match(/ActiveRecord::Migration\[#{Regexp.escape(version)}\]/, migration)
      assert_match(/t\.binary :payload, null: false, limit: 16\.megabytes - 1/, migration)
      assert_match(/t\.string :document_key, null: false, index: true/, migration)
    end
  end
end
