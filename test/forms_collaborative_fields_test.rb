# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/encrypted_document"
require_relative "../app/models/y/encrypted_document_update"
require "y/forms"

# The has_collaborative_fields macro: tier detection, the field-set document
# association, and the materializer writing declared fields back to their
# columns. Documents are built from Y.js fixture bytes (Y::Doc is read-only
# from Ruby).
class FormsCollaborativeFieldsTest < Minitest::Test
  class Ticket < ActiveRecord::Base
    self.table_name = "tickets"
    include Y::Forms::CollaborativeFields

    enum :status, { triage: "triage", active: "active", done: "done" }
    has_collaborative_fields :status, :priority, :urgent, :due_on, :summary, :description
  end

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
    Ticket.delete_all
    @ticket = Ticket.create!(title: "keep me")
  end

  # -- tier detection --------------------------------------------------------

  def test_detects_tiers_from_the_attributes
    assert_equal({ status: :lww,      # enum, despite the string column
                   priority: :lww,    # integer
                   urgent: :lww,      # boolean
                   due_on: :lww,      # date
                   summary: :text,    # string column
                   description: :text }, # text column
                 Ticket.collaborative_field_tiers)
  end

  def test_text_and_lww_kwargs_force_the_tier
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      include Y::Forms::CollaborativeFields

      has_collaborative_fields :priority, :summary, text: [:priority], lww: [:summary]
    end

    assert_equal({ priority: :text, summary: :lww }, klass.collaborative_field_tiers)
  end

  def test_unknown_attribute_raises
    error = assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include Y::Forms::CollaborativeFields

        has_collaborative_fields :no_such_column
      end
    end

    assert_match(/no_such_column.*not an attribute/, error.message)
  end

  def test_forced_name_must_be_declared
    assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include Y::Forms::CollaborativeFields

        has_collaborative_fields :summary, text: [:priority]
      end
    end
  end

  def test_a_field_cannot_be_forced_both_ways
    assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "tickets"
        include Y::Forms::CollaborativeFields

        has_collaborative_fields :summary, text: [:summary], lww: [:summary]
      end
    end
  end

  def test_models_without_the_macro_get_no_instance_api
    bare = Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      include Y::Forms::CollaborativeFields
    end

    assert_respond_to bare, :has_collaborative_fields, "the macro is available"
    refute bare.method_defined?(:find_or_create_collaborative_fields_document),
           "instance API arrives only with a declaration"
    refute bare.method_defined?(:refresh_collaborative_fields)
  end

  # -- the field-set document ------------------------------------------------

  def test_one_document_per_record_named_fields
    document = @ticket.find_or_create_collaborative_fields_document

    assert_equal @ticket, document.record
    assert_equal "fields", document.name
    assert_equal document, @ticket.collaborative_fields_document, "has_one"
    assert_equal document, @ticket.find_or_create_collaborative_fields_document, "created once, found after"
    assert_predicate @ticket, :collaborative_fields?
    assert @ticket.collaborative_field?(:status)
    refute @ticket.collaborative_field?(:title)
  end

  def test_destroying_the_record_sweeps_document_and_log
    @ticket.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)
    @ticket.destroy!

    assert_equal 0, Y::Document.count
    assert_equal 0, Y::DocumentUpdate.count, "the log follows the record's lifecycle"
  end

  def test_encrypted_field_set_wires_the_encrypted_document_class
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      def self.name = "Ticket"
      include Y::Forms::CollaborativeFields

      has_collaborative_fields :summary, encrypted: true
    end

    assert_equal Y::EncryptedDocument, klass.reflect_on_association(:collaborative_fields_document).klass
    record = klass.create!

    assert_instance_of Y::EncryptedDocument, record.find_or_create_collaborative_fields_document
  end

  def test_encrypted_field_set_materializes_and_stores_ciphertext
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      def self.name = "Ticket"
      include Y::Forms::CollaborativeFields

      has_collaborative_fields :summary, encrypted: true
    end
    record = klass.find(@ticket.id)
    document = record.find_or_create_collaborative_fields_document
    document.append(YjsFixtures::FormFields::FULL)

    assert record.refresh_collaborative_fields
    assert_equal "Fix the flaky spec", record.reload.summary, "materialization is unchanged by encryption"

    raw = Y::Document.connection.select_value(
      "SELECT payload FROM y_document_updates WHERE document_id = #{document.id} LIMIT 1"
    )

    assert_includes raw, '"p":', "payload rows hold the Active Record encryption envelope"
  end

  # -- the materializer ------------------------------------------------------

  def test_refresh_is_false_with_no_document_or_no_state
    refute @ticket.refresh_collaborative_fields, "no document yet"

    @ticket.find_or_create_collaborative_fields_document

    refute @ticket.refresh_collaborative_fields, "a document with no recorded state"
  end

  def test_refresh_writes_declared_fields_through_their_tiers_and_types
    @ticket.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)

    assert @ticket.refresh_collaborative_fields
    @ticket.reload

    assert_equal "active", @ticket.status, "enum assigned by name"
    assert_equal 7, @ticket.priority
    assert @ticket.urgent
    assert_equal Date.new(2026, 9, 1), @ticket.due_on, "LWW strings cast through the attribute type"
    assert_equal "Fix the flaky spec", @ticket.summary
    assert_equal "It fails on Tuesdays.", @ticket.description
  end

  def test_refresh_ignores_undeclared_map_keys
    # The fixture map carries "title" (a real column, not declared) and
    # "hacked" (no such attribute). Neither may be assigned: this is the
    # line between collaboration and mass assignment.
    @ticket.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)

    assert @ticket.refresh_collaborative_fields
    assert_equal "keep me", @ticket.reload.title
  end

  def test_refresh_applies_the_last_write
    document = @ticket.find_or_create_collaborative_fields_document
    document.append(YjsFixtures::FormFields::FULL)
    document.append(YjsFixtures::FormFields::STATUS_DONE)

    assert @ticket.refresh_collaborative_fields
    assert_equal "done", @ticket.reload.status
  end

  def test_refresh_is_idempotent
    @ticket.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)
    @ticket.refresh_collaborative_fields
    first = @ticket.reload.attributes

    assert @ticket.refresh_collaborative_fields
    assert_equal first, @ticket.reload.attributes
  end

  def test_refresh_saves_past_unrelated_model_validations
    klass = Class.new(Ticket) do
      def self.name = "Ticket"
      validates :title, absence: true
    end
    record = klass.find(@ticket.id)

    refute_predicate record, :valid?
    record.find_or_create_collaborative_fields_document.append(YjsFixtures::FormFields::FULL)

    assert record.refresh_collaborative_fields
    assert_equal "Fix the flaky spec", record.reload.summary
  end
end
