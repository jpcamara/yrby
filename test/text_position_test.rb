# frozen_string_literal: true

require "test_helper"

class TextPositionTest < Minitest::Test
  def test_a_relative_position_keeps_its_place_as_text_is_inserted_before_it
    doc = Y::Doc.new
    text = doc.get_text("markdown")
    text.insert(0, "# Title\nHello world\n")
    at_world = text.relative_position(text.to_s.index("world"))

    assert_equal text.to_s.index("world"), text.index_at(at_world)

    text.insert(0, "## Préface 😀\n")

    assert_equal text.to_s.index("world"), text.index_at(at_world)
  end

  def test_a_position_past_the_end_names_the_text_itself
    text = Y::Doc.new.get_text("markdown")
    text.insert(0, "abc")

    assert_equal 3, text.index_at(text.relative_position(text.length))
  end

  def test_a_position_in_another_text_resolves_to_nil
    doc = Y::Doc.new
    doc.get_text("other").insert(0, "elsewhere")
    position = doc.get_text("other").relative_position(2)

    assert_nil doc.get_text("markdown").index_at(position)
  end

  # Yjs: doc.getMap("fields").set("body", new Y.Text("one two")). Ruby
  # can't create a nested text, but it can edit one an editor made.
  NESTED_TEXT = "AQLt093dAwAnAQZmaWVsZHMEYm9keQIEAO3T3d0DAAdvbmUgdHdvAA=="

  def test_a_position_resolves_in_a_text_nested_in_a_map
    doc = Y::Doc.new
    doc.apply_update(NESTED_TEXT.unpack1("m"))
    body = doc.get_map("fields").get_text("body")
    position = body.relative_position(4)
    body.insert(0, "zero ")

    assert_equal 9, body.index_at(position)
  end
end
