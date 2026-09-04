# frozen_string_literal: true

require "test_helper"
require "rails"
require "rails/generators"
require "rails/generators/test_case"
require "generators/yrby_forms/install/install_generator"

class FormsInstallGeneratorTest < Rails::Generators::TestCase
  tests YrbyForms::Generators::InstallGenerator
  destination File.expand_path("../tmp/forms-generator-destination", __dir__)
  setup :prepare_destination

  def test_generates_the_channel_over_the_record_api
    run_generator

    assert_file "app/channels/form_fields_channel.rb" do |channel|
      assert_match "include Y::ActionCable", channel
      assert_match "Y::Collaborative.locate(params[:sgid], Y::Forms::DOCUMENT_NAME)", channel,
                   "the token resolves through the base sgid flow, pinned to the field-set purpose"
      assert_match "collaborative_fields?", channel, "the record must declare collaborative fields"
      assert_match "find_or_create_collaborative_fields_document", channel
      assert_match "refresh_collaborative_fields", channel,
                   "the channel materializes updates through the record API"
      assert_match "record.find_or_create_collaborative_fields_document.append", channel,
                   "storage routes through the record so encrypted field sets decrypt"
      assert_match "def authorized?\n    false", channel, "authorization defaults to false"
    end
    assert_no_file "app/models/y/document.rb" # models ship in the gem
  end

  def test_generates_the_storage_migration_via_yrby_tables
    run_generator

    assert_migration "db/migrate/create_y_tables.rb" do |migration|
      assert_match ":y_documents", migration
      assert_match "t.references :record, polymorphic: true", migration
      assert_match ":y_document_updates", migration
    end
  end
end
