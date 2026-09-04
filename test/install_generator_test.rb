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
      assert_match(/false/, channel, "authorization denies everyone by default")
    end
    assert_no_file "app/models/yrby_document_update.rb" # models ship in the gem
  end

  def test_generates_the_record_bound_channel_over_the_collaborative_api
    run_generator

    assert_file "app/channels/collaborative_document_channel.rb" do |channel|
      assert_match(/include Y::ActionCable\b/, channel)
      assert_match("Y::Collaborative.locate(params[:sgid], params[:field])", channel,
                   "the token resolves through the base sgid flow, scoped to the claimed field")
      assert_match("collaborative_document?, params[:field]", channel, "the record must declare the attribute")
      assert_match("find_or_create_collaborative_document(params[:field])", channel,
                   "storage routes through the record so encrypted attributes decrypt")
      assert_match("refresh_collaborative_document(params[:field])", channel,
                   "the channel materializes updates through the record API")
      assert_match("def authorized?\n    false", channel, "authorization defaults to false")
    end
  end

  def test_generates_the_storage_migration
    run_generator

    version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    assert_migration "db/migrate/create_y_tables.rb" do |migration|
      assert_match(/ActiveRecord::Migration\[#{Regexp.escape(version)}\]/, migration)
      assert_match(":y_documents", migration)
      assert_match("t.string :key, null: false, index: { unique: true }", migration)
      assert_match("t.references :record, polymorphic: true, null: true", migration)
      # 1 GB - 1 is the largest limit every adapter accepts: Postgres
      # raises above it; MySQL still maps it to longblob.
      assert_match(/t\.binary :state, limit: 1\.gigabyte - 1/, migration)
      assert_match(":y_document_updates", migration)
      assert_match("t.references :document", migration)
      assert_match(/t\.binary :payload, null: false, limit: 16\.megabytes - 1/, migration)
      assert_match("t.boolean :pending, null: false, default: false", migration)
    end
  end
end
