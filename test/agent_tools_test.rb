# frozen_string_literal: true

require "test_helper"
require "y/agent"

# The tools an agent gives its model, run against a document directly.
class AgentToolsTest < Minitest::Test
  # An agent that never joins: its doc is the test's, and edit writes to it.
  class Offline < Y::Agent
    def initialize(doc)
      super(nil, url: "ws://unused", lock: nil)
      @doc = doc
    end

    def edit(&) = @doc.edit(&)
  end

  def setup
    @doc = Y::Doc.new
    Y::Lexxy.append_heading(@doc, "Plan", tag: "h2")
    Y::Lexxy.append_paragraph(@doc, "Ship it on Fridya.")
    @agent = Offline.new(@doc)
  end

  def call(tool, **) = @agent.document_tools.find { |t| t.name == tool }.call(**)

  def texts = (0...root.size).map { |ordinal| root.xml_text(ordinal).text }

  def root = @doc.get_xml_text("root")

  def test_the_tools_are_named_for_the_model
    assert_equal %w[read_document rewrite_block insert_paragraph delete_block], @agent.document_tools.map(&:name)
  end

  def test_read_document_lists_each_block_by_id
    assert_equal "b1 (heading h2): Plan\nb2 (paragraph): Ship it on Fridya.", call("read_document")
    assert_equal "The document is empty.", Offline.new(Y::Doc.new).document_tools.first.call
  end

  def test_rewrite_block_replaces_its_text
    call("read_document")

    assert_equal "Rewrote b2.", call("rewrite_block", id: "b2", text: "Ship it on Friday.")
    assert_equal ["Plan", "Ship it on Friday."], texts
  end

  # A person adding a block above one doesn't move which block an id names.
  def test_an_id_stays_on_its_block_when_a_person_adds_one_above
    call("read_document")
    person = Y::Doc.new
    person.apply_update(@doc.encode_state_as_update)
    Y::Lexxy.insert_paragraph(person, 0, "Intro")
    @doc.apply_update(person.encode_state_as_update(@doc.encode_state_vector))

    call("rewrite_block", id: "b2", text: "Ship it on Friday.")

    assert_equal ["Intro", "Plan", "Ship it on Friday."], texts
    assert_equal "b3 (paragraph): Intro\nb1 (heading h2): Plan\nb2 (paragraph): Ship it on Friday.",
                 call("read_document")
  end

  def test_insert_paragraph_goes_after_a_block_or_at_the_end
    call("read_document")

    assert_equal "Added b3.", call("insert_paragraph", text: "Between", after: "b1")
    assert_equal "Added b4.", call("insert_paragraph", text: "After the last", after: "b2")
    assert_equal "Added b5.", call("insert_paragraph", text: "At the end")
    assert_equal ["Plan", "Between", "Ship it on Fridya.", "After the last", "At the end"], texts
  end

  def test_delete_block_removes_it_and_its_id_stops_working
    call("read_document")

    assert_equal "Deleted b1.", call("delete_block", id: "b1")
    assert_equal ["Ship it on Fridya."], texts
    assert_match(/no block b1/, call("delete_block", id: "b1")[:error])
    assert_match(/no block b1/, call("rewrite_block", id: "b1", text: "x")[:error])
    assert_match(/no block b1/, call("insert_paragraph", text: "x", after: "b1")[:error])
  end

  def test_an_id_the_model_made_up_is_an_error_it_can_recover_from
    assert_match(/Call read_document/, call("rewrite_block", id: "b9", text: "x")[:error])
  end

  # The model's arguments arrive as JSON, so a string key works too.
  def test_arguments_arrive_with_string_keys
    call("read_document")
    call("rewrite_block", "id" => "b1", "text" => "Plans")

    assert_equal "Plans", texts.first
  end
end
