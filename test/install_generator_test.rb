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

  def test_generates_no_app_code
    run_generator

    # The channel (Y::DocumentChannel) and the models ship in the gem, the
    # way Turbo ships Turbo::StreamsChannel — install lands only the
    # migration.
    assert_no_file "app/channels/document_channel.rb"
    assert_no_file "app/models/yrby_document_update.rb"
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
