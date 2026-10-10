# frozen_string_literal: true

require "test_helper"

class TextPositionTest < Minitest::Test
  def test_a_relative_position_keeps_its_place_as_text_is_inserted_before_it
    doc = Y::Doc.new
    text = doc.get_text("markdown")
    text.insert(0, "# Title\nHello world\n")
    at_world = text.relative_position(text.to_s.index("world"))

    assert_equal text.to_s.index("world"), doc.index_at(at_world, "markdown")

    text.insert(0, "## Preface\n")

    assert_equal text.to_s.index("world"), doc.index_at(at_world, "markdown")
  end

  def test_an_anchor_round_trips_and_resolves
    doc = Y::Doc.new
    text = doc.get_text("markdown")
    text.insert(0, "one two three")
    anchor = text.anchor(4)

    assert_equal "markdown", anchor.root
    assert_equal 4, doc.index_at(anchor)
    assert_equal 4, doc.index_at(Y::Anchor.from_json(anchor.to_json))
  end

  def test_a_position_past_the_end_names_the_text_itself
    doc = Y::Doc.new
    text = doc.get_text("markdown")
    text.insert(0, "abc")
    at_end = text.relative_position(text.length)

    assert_equal 3, doc.index_at(at_end, "markdown")
  end

  def test_a_position_in_another_root_resolves_to_nil
    doc = Y::Doc.new
    doc.get_text("other").insert(0, "elsewhere")
    position = doc.get_text("other").relative_position(2)

    assert_nil doc.index_at(position, "markdown")
  end
end
