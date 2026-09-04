# frozen_string_literal: true

# Booted by collaborative_engine_boot_test.rb to check the yrby-rails engine
# initializers against real Rails and real Action Text: the macros land on
# ActiveRecord::Base, collaborative_document_tag lands on FormBuilder, a
# document materializes Lexxy HTML into an Action Text body, encrypted:
# reaches both halves, and the yrby-forms adapter rides the same base.
# Prints ENGINE BOOT OK after all checks pass.
ENV["DATABASE_URL"] = "sqlite3::memory:"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "active_storage/engine"
require "action_text/engine"
require "yrby-rails"
require "yrby-forms"

require "tmpdir"

class BootCheckApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = true
  config.logger = Logger.new(File::NULL)
  config.secret_key_base = "boot-check"
  config.active_storage.service_configurations = { "test" => { "service" => "Disk", "root" => Dir.mktmpdir } }
  config.active_storage.service = :test
  config.active_record.encryption.primary_key = "test-primary-key" * 2
  config.active_record.encryption.deterministic_key = "test-deterministic-key" * 2
  config.active_record.encryption.key_derivation_salt = "test-key-derivation-salt" * 2
end

Rails.application.initialize!

abort "macro missing on ActiveRecord::Base" unless ActiveRecord::Base.respond_to?(:has_collaborative_document)
abort "rich-text macro missing" unless ActiveRecord::Base.respond_to?(:has_collaborative_rich_text)
abort "forms macro missing" unless ActiveRecord::Base.respond_to?(:has_collaborative_fields)
unless ActionView::Helpers::FormBuilder.method_defined?(:collaborative_document_tag)
  abort "collaborative_document_tag not prepended"
end
abort "forms helper not prepended" unless ActionView::Helpers::FormBuilder.method_defined?(:collaborative_fields)
abort "yrby engine model not autoloaded" unless Y::Document.table_name == "y_documents"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :y_documents do |t|
    t.string :key, null: false, index: { unique: true }
    t.references :record, polymorphic: true, null: true, index: false
    t.string :name
    t.binary :state
    t.timestamps
    t.index %i[record_type record_id name], unique: true, where: "record_type IS NOT NULL"
  end
  create_table :y_document_updates do |t|
    t.references :document, null: false, index: false
    t.binary :payload, null: false
    t.boolean :pending, null: false, default: false
    t.datetime :created_at, null: false
  end
  create_table :action_text_rich_texts do |t|
    t.string :name, null: false
    t.text :body
    t.references :record, null: false, polymorphic: true, index: false
    t.timestamps
    t.index %i[record_type record_id name], unique: true, name: :index_action_text_rich_texts_uniqueness
  end
  create_table :active_storage_blobs do |t|
    t.string :key, null: false, index: { unique: true }
    t.string :filename, null: false
    t.string :content_type
    t.text :metadata
    t.string :service_name, null: false
    t.bigint :byte_size, null: false
    t.string :checksum
    t.datetime :created_at, null: false
  end
  create_table :active_storage_attachments do |t|
    t.string :name, null: false
    t.references :record, null: false, polymorphic: true, index: false
    t.references :blob, null: false, index: false
    t.datetime :created_at, null: false
    t.index %i[record_type record_id name blob_id], unique: true, name: :index_active_storage_attachments_uniqueness
  end
  create_table :active_storage_variant_records do |t|
    t.belongs_to :blob, null: false, index: false
    t.string :variation_digest, null: false
  end
  create_table :boot_notes do |t|
    t.string :title
  end
  create_table :boot_tickets do |t|
    t.string :summary
    t.integer :priority
  end
end

class BootNote < ActiveRecord::Base
  has_collaborative_rich_text :body
  has_collaborative_rich_text :annotations, encrypted: true
end

# The real Action Text path: the macro must create the rich_text association.
abort "rich_text association missing" unless BootNote.reflect_on_association(:rich_text_body)
abort "document association missing" unless BootNote.reflect_on_association(:collaborative_document_body)
if BootNote.reflect_on_association(:rich_text_annotations).klass != ActionText::EncryptedRichText
  abort "encrypted: did not reach Action Text"
end
if BootNote.reflect_on_association(:collaborative_document_annotations).klass != Y::EncryptedDocument
  abort "encrypted: did not reach the document association"
end
abort "instance API missing on declaring model" unless BootNote.method_defined?(:find_or_create_collaborative_document)
if ActiveRecord::Base.method_defined?(:find_or_create_collaborative_document)
  abort "instance API leaked to plain models"
end

# Materialize the captured Lexxy fixture into the Action Text body. The
# comparison is against Action Text's canonicalized form of the same HTML:
# assignment parses through ActionText::Content, so what round-trips is the
# canonical serialization, not necessarily the exact input bytes (the
# byte-for-byte check runs against a plain column in the main suite).
fixtures = File.expand_path("../../ext/yrby/crates/lexical-html/src/fixtures", __dir__)
state = File.binread(File.join(fixtures, "lexxy_full.bin"))
expected = ActionText::Content.new(File.read(File.join(fixtures, "lexxy_full.html")).chomp).to_html

note = BootNote.create!
note.find_or_create_collaborative_document(:body).append(state)
abort "refresh did not materialize" unless note.refresh_collaborative_document(:body)
actual = note.reload.body.body.to_html
unless actual == expected
  abort "Action Text body did not match the rendered fixture:\n--- expected\n#{expected}\n--- actual\n#{actual}"
end

# The forms adapter on the same base, inside the booted app.
require_relative "../fixtures/yjs_fixtures"

class BootTicket < ActiveRecord::Base
  has_collaborative_fields :summary, :priority
end

abort "forms document association missing" unless BootTicket.reflect_on_association(:collaborative_document_fields)
ticket = BootTicket.create!
ticket.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)
abort "forms refresh did not materialize" unless ticket.refresh_collaborative_fields
ticket.reload
abort "forms text tier did not land" unless ticket.summary == "Fix the flaky spec"
abort "forms lww tier did not land" unless ticket.priority == 7

puts "ENGINE BOOT OK"
