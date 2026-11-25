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

    # Y::DocumentChannel and the models ship in the gem, so install only
    # creates the migration.
    assert_no_file "app/channels/document_channel.rb"
    assert_no_file "app/models/yrby_document_update.rb"
  end

  def test_optionally_generates_an_explicit_custom_channel
    run_generator ["--channel"]

    assert_file "app/channels/document_channel.rb" do |channel|
      assert_includes channel, "include Y::ActionCable"
      assert_includes channel, "def subscribed = sync_subscribed(params[:id])"
      assert_includes channel, "def receive(data) = sync_receive(data, params[:id])"
      refute_includes channel, "authorized?(params[:id])"
      assert_includes channel, "def authorized?(_document_key)"
      assert_match(/def authorized\?\(_document_key\)\s+false/, channel)
      assert_includes channel, "Y::Document.load_state(key)"
      assert_includes channel, "Y::Document.append(key, update)"
    end
    assert_migration "db/migrate/create_y_tables.rb"
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

  def test_adds_no_pins_without_an_importmap
    run_generator

    assert_no_file "config/importmap.rb"
  end

  def test_pins_the_shipped_javascript_in_an_importmap_app
    write_importmap %(pin "application"\n)

    run_generator

    assert_file "config/importmap.rb" do |importmap|
      assert_match 'pin "application"', importmap
      assert_match 'pin "yrby-client", to: "yrby/yrby-client.js"', importmap
      assert_match 'pin "yrby-client/element", to: "yrby/yrby-client.js"', importmap
      assert_match 'pin "yjs", to: "yrby/yjs.js"', importmap
      assert_match 'pin "@rails/actioncable", to: "actioncable.esm.js"', importmap
    end
  end

  # Every file the generator pins into the gem exists, and the gemspec ships it.
  def test_pinned_assets_ship_in_the_gem
    write_importmap ""

    run_generator

    root = File.expand_path("..", __dir__)
    importmap = File.read(File.join(destination_root, "config/importmap.rb"))
    pinned = importmap.scan(%r{to: "(yrby/[^"]+)"}).flatten.uniq.sort
    shipped = Gem::Specification.load(File.join(root, "yrby-rails.gemspec")).files

    assert_equal %w[yrby/yjs.js yrby/yrby-client.js], pinned
    pinned.each { |path| assert_includes shipped, "app/assets/javascript/#{path}" }
  end

  def test_running_it_twice_adds_each_pin_once
    write_importmap ""

    run_generator
    run_generator

    assert_file "config/importmap.rb" do |importmap|
      assert_equal 1, importmap.scan('pin "yjs"').length
      assert_equal 2, importmap.scan("yrby/yrby-client.js").length
    end
  end

  # An app that already pins yjs keeps its own pin, and the page still loads
  # one copy of it.
  def test_keeps_a_pin_the_app_already_has
    write_importmap %(pin "yjs", to: "https://cdn.example/yjs.js"\n)

    run_generator

    assert_file "config/importmap.rb" do |importmap|
      assert_equal 1, importmap.scan('pin "yjs"').length
      assert_match 'pin "yjs", to: "https://cdn.example/yjs.js"', importmap
      assert_match 'pin "yrby-client", to: "yrby/yrby-client.js"', importmap
    end
  end

  private

  def write_importmap(content)
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/importmap.rb"), content)
  end
end
