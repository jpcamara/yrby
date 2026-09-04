# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require "y/collaborative"
require "action_view"
require "global_id"
require "json"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# collaborative_document_tag: the one FormBuilder method editor helpers
# build on. It emits the collaboration element with the doc id, channel,
# signed token, and presence identity; the editor supplies only its custom
# element name.
class CollaborativeFormBuilderTest < Minitest::Test
  class Note < ActiveRecord::Base
    self.table_name = "notes"
    include GlobalID::Identification
    include Y::Collaborative

    has_collaborative_rich_text :body
  end

  FakeUser = Data.define(:name) do
    def try(attribute) = respond_to?(attribute) ? public_send(attribute) : nil
  end

  ActionView::Helpers::FormBuilder.prepend(Y::Collaborative::FormBuilder) # as the engine does

  def setup
    @note = Note.create!
    @view = ActionView::Base.empty
    user = FakeUser.new(name: "Ada")
    @view.define_singleton_method(:current_user) { user }
    @form = ActionView::Helpers::FormBuilder.new("note", @note, @view, {})
  end

  def teardown
    Y::Collaborative.identity = nil # back to the default lambda
    Note.delete_all
    Y::Document.delete_all
  end

  def element_attributes(html, element)
    fragment = html[/<#{element}[^>]*>/]
    fragment.scan(/([\w-]+)="([^"]*)"/).to_h.transform_values { |v| CGI.unescapeHTML(v) }
  end

  def test_emits_the_collaboration_wiring_for_the_supplied_element
    html = @form.collaborative_document_tag(:body, element: "my-editor-collaboration")

    assert_match %r{<my-editor-collaboration[^>]*></my-editor-collaboration>}, html

    attrs = element_attributes(html, "my-editor-collaboration")

    assert_equal "collaborative_form_builder_test_note-#{@note.id}-body", attrs["doc-id"]
    assert_equal "CollaborativeDocumentChannel", attrs["channel-name"], "the generated channel is the default"
    assert_equal "Ada", attrs["name"]
    assert_match(/\Ahsl\(\d+, 70%, 45%\)\z/, attrs["color"], "derived presence color is stable per name")

    params = JSON.parse(attrs["channel-params"])

    assert_equal "body", params["field"]
    assert_equal @note, Y::Collaborative.locate(params["sgid"], :body), "the signed token round-trips"
    assert_nil Y::Collaborative.locate(params["sgid"], :other), "and only for its own attribute"
  end

  def test_channel_name_and_identity_can_be_overridden
    Y::Collaborative.identity = ->(_view) { { name: "Grace", color: "#111111" } }

    attrs = element_attributes(
      @form.collaborative_document_tag(:body, element: "my-editor", channel: "MyChannel"), "my-editor"
    )

    assert_equal "MyChannel", attrs["channel-name"]
    assert_equal "Grace", attrs["name"]
    assert_equal "#111111", attrs["color"]
  end

  def test_per_call_name_and_color_win_over_the_identity
    attrs = element_attributes(
      @form.collaborative_document_tag(:body, element: "my-editor", name: "Joan", color: "#222222"), "my-editor"
    )

    assert_equal "Joan", attrs["name"]
    assert_equal "#222222", attrs["color"]
  end

  def test_extra_attributes_and_block_content_pass_through
    html = @form.collaborative_document_tag(:body, element: "my-editor", class: "wide") do
      "INNER".html_safe
    end

    assert_match %r{<my-editor[^>]*>INNER</my-editor>}, html
    assert_equal "wide", element_attributes(html, "my-editor")["class"]
  end

  def test_rejects_non_collaborative_attributes_and_records
    assert_raises(ArgumentError) { @form.collaborative_document_tag(:title, element: "my-editor") }

    unpersisted = ActionView::Helpers::FormBuilder.new("note", Note.new, @view, {})

    assert_raises(ArgumentError) { unpersisted.collaborative_document_tag(:body, element: "my-editor") }

    bare_class = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      include Y::Collaborative
    end
    bare_form = ActionView::Helpers::FormBuilder.new("note", bare_class.new, @view, {})

    assert_raises(ArgumentError) { bare_form.collaborative_document_tag(:body, element: "my-editor") }
  end
end
