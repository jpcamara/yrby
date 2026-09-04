# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/encrypted_document"
require_relative "../app/models/y/encrypted_document_update"
require "y/collaborative"
require "global_id"
require "json"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# The collaborative-document base in yrby-rails: has_collaborative_document
# (association + sgid + the refresh shell around a registered materialize
# block) and has_collaborative_rich_text (render the document to HTML into
# the attribute). Documents are built from fixture bytes (Y::Doc is
# read-only from Ruby); the Lexxy pair is the same byte-parity fixture the
# renderer tests pin against.
class CollaborativeDocumentTest < Minitest::Test
  LEXXY_FIXTURES = File.expand_path("../ext/yrby/crates/lexical-html/src/fixtures", __dir__)

  def lexxy_state = File.binread(File.join(LEXXY_FIXTURES, "lexxy_full.bin"))
  def lexxy_html = File.read(File.join(LEXXY_FIXTURES, "lexxy_full.html")).chomp

  # The plain-column path: no has_rich_text anywhere, so the macro's
  # capability check must fall back to the body text column.
  class Note < ActiveRecord::Base
    self.table_name = "notes"
    include GlobalID::Identification
    include Y::Collaborative

    has_collaborative_rich_text :body
  end

  # The Action Text branch of the macro, with has_rich_text stubbed to
  # record its invocation (the real integration runs in the engine boot
  # test).
  class RichNote < ActiveRecord::Base
    self.table_name = "notes"
    include Y::Collaborative

    class << self
      def rich_text_declarations = @rich_text_declarations ||= []

      def has_rich_text(name, **options) # rubocop:disable Naming/PredicatePrefix
        rich_text_declarations << [name, options]
      end
    end

    has_collaborative_rich_text :body
    has_collaborative_rich_text :title, encrypted: true

    # Match Action Text's writer, which reads the attribute while finding
    # or building the rich text record. This catches recursive
    # materialization.
    def body=(value)
      body
      super
    end
  end

  # The primitive with a multi-column materialize block: several columns
  # assigned from one document.
  class FieldsTicket < ActiveRecord::Base
    self.table_name = "tickets"
    include Y::Collaborative

    has_collaborative_document :fields do |doc, record|
      entries = JSON.parse(doc.read_map("fields") || "{}")
      record.assign_attributes(
        priority: entries["priority"],
        summary: doc.read_text("fields/summary"),
        description: doc.read_text("fields/description")
      )
    end
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    Note.delete_all
    @note = Note.create!(title: "keep me")
  end

  def teardown
    Y::Collaborative.rich_text_renderer = nil # back to the Y::Lexxy default
  end

  # -- the document association ---------------------------------------------

  def test_one_document_per_record_per_attribute
    document = @note.find_or_create_collaborative_document(:body)

    assert_equal @note, document.record
    assert_equal "body", document.name
    assert_equal document, @note.collaborative_document(:body), "has_one"
    assert_equal document, @note.find_or_create_collaborative_document(:body), "created once, found after"
    assert @note.collaborative_document?(:body)
    refute @note.collaborative_document?(:title)
  end

  def test_no_document_until_first_use
    assert_nil @note.collaborative_document(:body)
  end

  def test_destroying_the_record_sweeps_document_and_log
    @note.find_or_create_collaborative_document(:body).append(lexxy_state)
    @note.destroy!

    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count, "the log follows the record's lifecycle"
  end

  def test_encrypted_document_wires_the_encrypted_class
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_document :body, encrypted: true
    end

    assert_equal Y::EncryptedDocument, klass.reflect_on_association(:collaborative_document_body).klass
    record = klass.create!

    assert_instance_of Y::EncryptedDocument, record.find_or_create_collaborative_document(:body)
  end

  def test_models_without_a_declaration_get_no_instance_api
    bare = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      include Y::Collaborative
    end

    assert_respond_to bare, :has_collaborative_document, "the macro is available"
    refute bare.method_defined?(:find_or_create_collaborative_document),
           "instance API arrives only with a declaration"
    refute bare.method_defined?(:refresh_collaborative_document)
  end

  def test_undeclared_names_raise
    assert_raises(ArgumentError) { @note.find_or_create_collaborative_document(:nope) }
    assert_raises(ArgumentError) { @note.refresh_collaborative_document(:nope) }
    assert_raises(ArgumentError) { @note.collaborative_sgid(:nope) }
  end

  # -- the refresh shell -----------------------------------------------------

  def test_refresh_is_false_with_no_document_or_no_state
    refute @note.refresh_collaborative_document(:body), "no document yet"

    @note.find_or_create_collaborative_document(:body)

    refute @note.refresh_collaborative_document(:body), "a document with no recorded state"
  end

  def test_rich_text_materializes_lexxy_html_into_the_plain_column_byte_for_byte
    @note.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert @note.refresh_collaborative_document(:body)
    assert_equal lexxy_html, @note.reload.body, "the default renderer is Y::Lexxy, byte-parity with the editor"
    assert_equal "keep me", @note.title, "other columns are untouched"
  end

  def test_materialize_block_receives_the_rebuilt_doc_and_the_record
    received = nil
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_document(:body) { |doc, record| received = [doc, record] }
    end
    record = klass.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert record.refresh_collaborative_document(:body)
    assert_instance_of Y::Doc, received.first
    assert_equal record, received.last
  end

  def test_multi_column_materialize_assigns_several_columns_from_one_document
    ticket = FieldsTicket.create!
    ticket.find_or_create_collaborative_document(:fields).append(YjsFixtures::FormFields::FULL)

    assert ticket.refresh_collaborative_document(:fields)
    ticket.reload

    assert_equal 7, ticket.priority
    assert_equal "Fix the flaky spec", ticket.summary
    assert_equal "It fails on Tuesdays.", ticket.description
  end

  def test_a_declaration_without_a_block_syncs_but_does_not_materialize
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_document :body
    end
    record = klass.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    refute record.refresh_collaborative_document(:body), "nothing registered to materialize"
    assert_nil record.reload.body
  end

  def test_a_false_return_from_the_block_skips_the_save
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_document :body do |_doc, record|
        record.title = "should not persist"
        false
      end
    end
    record = klass.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    refute record.refresh_collaborative_document(:body)
    assert_equal "keep me", record.reload.title
  end

  def test_refresh_saves_past_unrelated_model_validations
    klass = Class.new(Note) do
      def self.name = "Note"
      validates :title, absence: true
    end
    record = klass.find(@note.id)

    refute_predicate record, :valid?
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert record.refresh_collaborative_document(:body)
    assert_equal lexxy_html, record.reload.body
  end

  def test_refresh_works_on_a_strict_loading_record
    @note.find_or_create_collaborative_document(:body).append(lexxy_state)
    @note.strict_loading!

    assert @note.refresh_collaborative_document(:body)
    assert_equal lexxy_html, @note.reload.body
  end

  # -- the rich-text renderer ------------------------------------------------

  def test_action_text_branch_declares_has_rich_text_with_options_passed_through
    assert_includes RichNote.rich_text_declarations, [:body, {}]
    assert_includes RichNote.rich_text_declarations, [:title, { encrypted: true }],
                    "encrypted: reaches Action Text"
    assert_equal Y::EncryptedDocument, RichNote.reflect_on_association(:collaborative_document_title).klass,
                 "encrypted: reaches the document association"
  end

  def test_action_text_branch_materializes_through_the_attribute_writer
    record = RichNote.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert record.refresh_collaborative_document(:body)
    assert_equal lexxy_html, record.reload.body
  end

  def test_renderer_option_overrides_the_default
    received = nil
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_rich_text :body, renderer: lambda { |doc, record:, name:|
        received = [doc.class, record, name]
        "<p>via renderer</p>"
      }
    end
    record = klass.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert record.refresh_collaborative_document(:body)
    assert_equal "<p>via renderer</p>", record.reload.body
    assert_equal [Y::Doc, record, :body], received, "the renderer contract is (doc, record:, name:)"
  end

  def test_a_block_renders_too
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      def self.name = "Note"
      include Y::Collaborative

      has_collaborative_rich_text(:body) { |doc| "<p>#{doc.class}</p>" }
    end
    record = klass.find(@note.id)
    record.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert record.refresh_collaborative_document(:body)
    assert_equal "<p>Y::Doc</p>", record.reload.body
  end

  def test_renderer_and_block_together_raise
    assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "notes"
        include Y::Collaborative

        has_collaborative_rich_text(:body, renderer: ->(_doc, **) { "" }) { |_doc| "" }
      end
    end
  end

  def test_the_module_level_renderer_config_is_the_default
    Y::Collaborative.rich_text_renderer = ->(_doc, **) { "<p>configured</p>" }
    @note.find_or_create_collaborative_document(:body).append(lexxy_state)

    assert @note.refresh_collaborative_document(:body)
    assert_equal "<p>configured</p>", @note.reload.body
  end

  def test_a_nil_render_skips_the_save
    Y::Collaborative.rich_text_renderer = ->(_doc, **) {}
    @note.update!(body: "untouched")
    @note.find_or_create_collaborative_document(:body).append(lexxy_state)

    refute @note.refresh_collaborative_document(:body)
    assert_equal "untouched", @note.reload.body
  end

  # -- the sgid flow ---------------------------------------------------------

  def test_sgid_round_trips_for_its_own_attribute_only
    sgid = @note.collaborative_sgid(:body)

    assert_equal @note, Y::Collaborative.locate(sgid, :body)
    assert_nil Y::Collaborative.locate(sgid, :other_field),
               "a token minted for :body must not locate through another attribute's purpose"
    assert_nil Y::Collaborative.locate(sgid, :fields)
  end

  def test_sgid_purpose_is_the_documented_contract
    assert_equal "yrby/body", Y::Collaborative.sgid_purpose(:body)
    assert_equal @note, GlobalID::Locator.locate_signed(@note.collaborative_sgid(:body), for: "yrby/body")
  end

  def test_tampered_and_foreign_tokens_locate_nothing
    sgid = @note.collaborative_sgid(:body)

    assert_nil Y::Collaborative.locate(sgid.reverse, :body), "a tampered token verifies as nothing"
    assert_nil Y::Collaborative.locate(nil, :body)
    assert_nil GlobalID::Locator.locate_signed(sgid, for: :something_else),
               "the raw token is purpose-scoped for any other consumer too"
  end

  def test_a_token_locates_only_its_own_record
    other = Note.create!

    assert_equal @note, Y::Collaborative.locate(@note.collaborative_sgid(:body), :body)
    assert_equal other, Y::Collaborative.locate(other.collaborative_sgid(:body), :body)
    refute_equal @note.collaborative_sgid(:body), other.collaborative_sgid(:body)
  end

  def test_a_destroyed_records_token_locates_nothing
    sgid = @note.collaborative_sgid(:body)
    @note.destroy!

    assert_nil Y::Collaborative.locate(sgid, :body), "RecordNotFound resolves to nil, not an exception"
  end
end
