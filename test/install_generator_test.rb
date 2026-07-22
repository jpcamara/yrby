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
      assert_match(/on_load { \|key\| YrbyDocumentUpdate\.load\(key\) }/, channel)
      assert_match(/on_change { \|key, update\| YrbyDocumentUpdate\.append\(key, update\) }/, channel)
      assert_match(/sync_subscribed\(params\[:id\]\)/, channel)
      assert_match(/sync_receive\(data, params\[:id\]\)/, channel)
      assert_match(/return reject unless authorized\?\(params\[:id\]\)/, channel,
                   "the channel must fail closed until the app authorizes access")
    end
  end

  def test_generates_the_store_and_model
    run_generator

    assert_file "app/models/yrby_document_update.rb" do |model|
      assert_match(/class YrbyDocumentUpdate < ApplicationRecord/, model)
      assert_match(/include Y::ActionCable::UpdateLog/, model)
    end
    assert_no_file "app/models/yrby_document_store.rb"
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

  def test_custom_model_name_carries_through_every_generated_file
    run_generator ["DocumentRevision"]

    assert_file "app/models/document_revision.rb" do |model|
      assert_match(/class DocumentRevision < ApplicationRecord/, model)
      assert_match(/include Y::ActionCable::UpdateLog/, model)
      assert_no_match(/YrbyDocument/, model)
    end
    assert_file "app/channels/document_channel.rb" do |channel|
      assert_match(/DocumentRevision\.load/, channel)
      assert_no_match(/YrbyDocument/, channel)
    end
    assert_migration "db/migrate/create_document_revisions.rb" do |migration|
      assert_match(/class CreateDocumentRevisions/, migration)
      assert_match(/:document_revisions/, migration)
    end
    assert_no_file "app/models/yrby_document_update.rb"
  end

  def test_namespaced_model_name_is_rejected
    # Thor reports the error itself rather than raising through start.
    error = capture(:stderr) { run_generator ["Admin::DocumentRevision"] }

    assert_match(/top-level model name/, error)
    assert_no_file "app/channels/document_channel.rb"
    assert_no_file "app/models/admin/document_revision.rb"
  end
end
