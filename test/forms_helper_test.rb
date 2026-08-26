# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require "y/forms"
require "action_view"
require "global_id"
require "json"

GlobalID.app ||= "yrby-forms-test"
SignedGlobalID.app ||= "yrby-forms-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-forms-test-secret")

# The form helper pair: collaborative_fields renders the <collaborative-form>
# container (channel, signed sgid, doc key, identity) and collaborative_field
# wraps the stock input for each attribute in <collaborative-field>.
class FormsHelperTest < Minitest::Test
  class Ticket < ActiveRecord::Base
    self.table_name = "tickets"
    include GlobalID::Identification
    include Y::Forms::CollaborativeFields

    enum :status, { triage: "triage", active: "active", done: "done" }
    has_collaborative_fields :status, :priority, :urgent, :due_on, :summary, :description
  end

  FakeUser = Data.define(:name) do
    def try(attribute) = respond_to?(attribute) ? public_send(attribute) : nil
  end

  ActionView::Helpers::FormBuilder.prepend(Y::Forms::FormBuilder) # as the engine does

  def setup
    @ticket = Ticket.create!
    @view = ActionView::Base.empty
    user = FakeUser.new(name: "Ada")
    @view.define_singleton_method(:current_user) { user }
    @form = ActionView::Helpers::FormBuilder.new("ticket", @ticket, @view, {})
  end

  def teardown
    Y::Forms.identity = nil # back to the default lambda
    Ticket.delete_all
    Y::Document.delete_all
  end

  def element_attributes(html, element = "collaborative-form")
    fragment = html[/<#{element}[^>]*>/]
    fragment.scan(/([\w-]+)="([^"]*)"/).to_h.transform_values { |v| CGI.unescapeHTML(v) }
  end

  def test_container_carries_channel_sgid_doc_key_and_identity
    html = @form.collaborative_fields { "INNER".html_safe }

    assert_match %r{<collaborative-form[^>]*>INNER</collaborative-form>}, html

    attrs = element_attributes(html)

    assert_equal "FormFieldsChannel", attrs["channel"]
    assert_equal "forms_helper_test_ticket-#{@ticket.id}-fields", attrs["doc-key"]
    assert_equal "Ada", attrs["name"]
    assert_match(/\Ahsl\(\d+, 70%, 45%\)\z/, attrs["color"], "derived presence color is stable per name")
    assert_equal @ticket, GlobalID::Locator.locate_signed(attrs["sgid"], for: Y::Forms.sgid_purpose),
                 "the signed GlobalID round-trips to the record"
  end

  def test_sgid_is_purpose_scoped
    attrs = element_attributes(@form.collaborative_fields { "".html_safe })

    assert_nil GlobalID::Locator.locate_signed(attrs["sgid"], for: :something_else),
               "a signed id minted for collaboration must not verify for another purpose"
  end

  def test_identity_lambda_supplies_name_and_color
    Y::Forms.identity = ->(_view) { { name: "Grace", color: "#111111" } }

    attrs = element_attributes(@form.collaborative_fields { "".html_safe })

    assert_equal "Grace", attrs["name"]
    assert_equal "#111111", attrs["color"]
  end

  def test_field_wrapper_carries_name_and_tier
    lww = element_attributes(@form.collaborative_field(:status), "collaborative-field")

    assert_equal "status", lww["name"]
    assert_equal "lww", lww["tier"]

    text = element_attributes(@form.collaborative_field(:description), "collaborative-field")

    assert_equal "description", text["name"]
    assert_equal "text", text["tier"]
  end

  def test_field_renders_the_stock_input_for_the_attribute
    assert_match(/<select[^>]*name="ticket\[status\]"/, @form.collaborative_field(:status), "enum renders a select")
    assert_includes @form.collaborative_field(:status), %(<option value="done">done</option>)
    assert_match(/<input[^>]*type="number"/, @form.collaborative_field(:priority))
    assert_match(/<input[^>]*type="checkbox"/, @form.collaborative_field(:urgent))
    assert_match(/<input[^>]*type="date"/, @form.collaborative_field(:due_on))
    assert_match(/<input[^>]*type="text"/, @form.collaborative_field(:summary), "string column renders a text input")
    assert_match(/<textarea/, @form.collaborative_field(:description), "text column renders a textarea")
  end

  def test_field_accepts_a_block_input
    html = @form.collaborative_field(:status) { %(<input id="custom">).html_safe }

    assert_match %r{<collaborative-field[^>]*><input id="custom"></collaborative-field>}, html
  end

  def test_rejects_non_collaborative_fields_and_records
    assert_raises(ArgumentError) { @form.collaborative_field(:title) }

    bare_class = Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      include Y::Forms::CollaborativeFields
    end
    bare_form = ActionView::Helpers::FormBuilder.new("ticket", bare_class.new, @view, {})

    assert_raises(ArgumentError) { bare_form.collaborative_fields { "".html_safe } }

    unpersisted = ActionView::Helpers::FormBuilder.new("ticket", Ticket.new, @view, {})

    assert_raises(ArgumentError) { unpersisted.collaborative_fields { "".html_safe } }
  end
end
