# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/forms"
require "action_view"
require "base64"

# has_collaborative_fields with column:. The document is a Base64 column of
# the record, the form posts it with the fields, and each save merges it into
# the stored one.
class FormsColumnTest < Minitest::Test
  class Ticket < ActiveRecord::Base
    self.table_name = "tickets"
    include Y::Forms::CollaborativeFields

    enum :status, { triage: "triage", active: "active", done: "done" }
    has_collaborative_fields :status, :priority, :summary, :description, column: :fields_ydoc
  end

  ActionView::Helpers::FormBuilder.prepend(Y::Forms::FormBuilder) # as the engine does

  def setup
    @ticket = Ticket.create!(title: "keep me", summary: "Fix the spec", description: "It fails.")
  end

  def teardown
    Ticket.delete_all
  end

  # -- the macro -------------------------------------------------------------

  def test_the_document_is_the_column_and_no_collaborative_document_is_declared
    assert_equal :fields_ydoc, Ticket.collaborative_fields_column
    assert_empty Ticket.collaborative_document_options
    assert_nil Ticket.reflect_on_association(:collaborative_fields_document)
  end

  def test_rejects_a_missing_column_and_encrypted
    assert_raises(ArgumentError) { ticket_class { has_collaborative_fields :summary, column: :nope } }
    assert_raises(ArgumentError) do
      ticket_class { has_collaborative_fields :summary, column: :fields_ydoc, encrypted: true }
    end
  end

  # -- saving ----------------------------------------------------------------

  def test_a_record_created_in_ruby_gets_a_document_of_its_text_fields
    doc = document(@ticket.reload.fields_ydoc)

    assert_equal "Fix the spec", doc.read_text("fields/summary")
    assert_equal "It fails.", doc.read_text("fields/description")
  end

  def test_two_edits_of_one_document_both_survive
    base = @ticket.fields_ydoc
    ada = edit(base) { |doc| doc.get_text("fields/description").insert(9, " On Tuesdays.") }
    grace = edit(base) { |doc| doc.get_text("fields/description").insert(0, "Urgent: ") }

    Ticket.find(@ticket.id).update!(description: "It fails. On Tuesdays.", fields_ydoc: ada)
    Ticket.find(@ticket.id).update!(description: "Urgent: It fails.", fields_ydoc: grace)

    @ticket.reload

    assert_equal "Urgent: It fails. On Tuesdays.", @ticket.description
    assert_equal "Urgent: It fails. On Tuesdays.", document(@ticket.fields_ydoc).read_text("fields/description")
  end

  def test_declared_fields_are_read_from_the_document_through_their_types
    state = edit(@ticket.fields_ydoc) do |doc|
      fields = doc.get_map("fields")
      fields["status"] = "active"
      fields["priority"] = "7"
      fields["title"] = "hacked" # a real column, not declared
    end

    @ticket.update!(fields_ydoc: state)
    @ticket.reload

    assert_equal "active", @ticket.status
    assert_equal 7, @ticket.priority
    assert_equal "keep me", @ticket.title
  end

  def test_a_value_assigned_in_ruby_is_replaced_by_the_documents
    @ticket.update!(summary: "Rewritten in Ruby", title: "Renamed")

    assert_equal "Fix the spec", @ticket.reload.summary
    assert_equal "Renamed", @ticket.title, "other attributes save as usual"
  end

  def test_a_text_field_the_document_lacks_is_added_from_its_column
    only_summary = Y::Doc.new
    only_summary.get_text("fields/summary").insert(0, "Fix the spec")
    @ticket.update_columns(fields_ydoc: encode(only_summary))

    state = edit(@ticket.fields_ydoc) { |doc| doc.get_text("fields/summary").insert(0, "Please: ") }
    @ticket.update!(fields_ydoc: state)
    @ticket.reload

    assert_equal "Please: Fix the spec", @ticket.summary
    assert_equal "It fails.", @ticket.description
    assert_equal "It fails.", document(@ticket.fields_ydoc).read_text("fields/description")
  end

  def test_a_field_emptied_in_the_document_stays_empty
    @ticket.update!(fields_ydoc: edit(@ticket.fields_ydoc) { |doc| doc.get_text("fields/summary").clear })

    assert_equal "", @ticket.reload.summary
  end

  def test_a_save_that_changes_no_field_leaves_the_document_alone
    state = @ticket.fields_ydoc

    queries = count_queries { @ticket.update!(title: "Renamed") }

    assert_equal state, @ticket.reload.fields_ydoc
    assert_equal 1, queries, "no read of the stored document"
  end

  def test_a_column_that_is_not_a_document_fails_the_save
    ["not base64!", Base64.strict_encode64("not a document")].each do |state|
      refute @ticket.update(fields_ydoc: state)
      assert @ticket.errors.of_kind?(:fields_ydoc, :invalid)
    end

    assert_equal "Fix the spec", document(@ticket.reload.fields_ydoc).read_text("fields/summary")
  end

  # -- the form helper -------------------------------------------------------

  def test_the_container_carries_the_document_under_the_columns_param_name
    html = form_for(@ticket).collaborative_fields(autosave: true) { "".html_safe }
    attributes = html[/<collaborative-fields([^>]*)>/, 1].scan(/([\w-]+)="([^"]*)"/).to_h

    assert_equal "ticket[fields_ydoc]", attributes["name"]
    assert_equal @ticket.fields_ydoc, CGI.unescapeHTML(attributes["value"])
    assert attributes.key?("autosave")
  end

  def test_a_new_records_form_starts_from_a_document_of_its_text_fields
    form = form_for(Ticket.new(summary: "Untitled"))
    html = form.collaborative_fields { form.collaborative_field(:summary) }
    state = CGI.unescapeHTML(html[/<collaborative-fields[^>]* value="([^"]*)"/, 1])

    assert_equal "Untitled", document(state).read_text("fields/summary")
    assert_match(/<collaborative-field name="summary" tier="text"><input[^>]*value="Untitled"/, html)
  end

  private

  def ticket_class(&)
    Class.new(ActiveRecord::Base) do
      self.table_name = "tickets"
      include Y::Forms::CollaborativeFields

      class_eval(&)
    end
  end

  def form_for(ticket) = ActionView::Helpers::FormBuilder.new("ticket", ticket, ActionView::Base.empty, {})

  def document(state)
    Y::Doc.new.tap { |doc| doc.apply_update(Base64.strict_decode64(state)) }
  end

  def encode(doc) = Base64.strict_encode64(doc.encode_state_as_update)

  # Another browser's copy of `state`, with the block editing it.
  def edit(state)
    doc = document(state)
    yield doc
    encode(doc)
  end

  def count_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end
end
