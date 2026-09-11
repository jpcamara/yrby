# frozen_string_literal: true

require "test_helper"

# Y::XmlText is the live handle a Ruby process writes rich text through, and
# Y::Lexical's helpers build Lexical's exact node shape on top of it. The
# renderer is the oracle: what Ruby writes must render the same as what a
# person typed in the editor.
class XmlTextTest < Minitest::Test
  PARAGRAPH = Y::Lexical::PARAGRAPH_ATTRIBUTES
  TEXT = Y::Lexical::TEXT_ATTRIBUTES

  def test_a_root_xml_text_starts_empty
    root = Y::Doc.new.get_xml_text("root")

    assert_kind_of Y::XmlText, root
    assert_equal 0, root.length
    assert_equal 0, root.xml_text_count
    assert_predicate root, :empty?
  end

  def test_a_block_is_an_embedded_xml_text_with_attributes_and_a_text_node
    doc = Y::Doc.new
    block = doc.get_xml_text("root").push_xml_text(PARAGRAPH)
    block.insert_embed(0, TEXT)
    block.insert(1, "Hello from Ruby")

    assert_equal 1, doc.get_xml_text("root").xml_text_count
    assert_equal "Hello from Ruby", doc.read_xml("root")
  end

  def test_blocks_are_addressed_by_ordinal_and_survive_other_edits
    doc = Y::Doc.new
    root = doc.get_xml_text("root")
    first = Y::Lexical.append_paragraph(doc, "first")
    Y::Lexical.append_paragraph(doc, "second")
    first.insert(first.length, " and more") # the first handle still points at block 0

    assert_equal 2, root.xml_text_count
    assert_equal "first and more\nsecond", doc.read_xml("root")
    assert_includes root.xml_text(1).to_s, "second"
  end

  def test_what_ruby_writes_renders_like_what_a_person_typed
    doc = Y::Doc.new
    Y::Lexical.append_paragraph(doc, "Verify the rollout on the canary fleet.")

    # The exact HTML the renderer produces for the same paragraph typed in Lexxy.
    assert_equal "<p>Verify the rollout on the canary fleet.</p>", Y::Lexxy.new(doc).to_html("root")
  end

  def test_a_heading_renders_as_a_heading
    doc = Y::Doc.new
    Y::Lexical.append_heading(doc, "Launch Readiness", tag: "h2")
    Y::Lexical.append_paragraph(doc, "Body.")

    assert_equal "<h2>Launch Readiness</h2><p>Body.</p>", Y::Lexxy.new(doc).to_html("root")
  end

  def test_the_update_round_trips_as_a_diff_another_peer_applies
    doc = Y::Doc.new
    before = doc.encode_state_vector
    Y::Lexical.append_paragraph(doc, "sent as a diff")
    update = doc.encode_state_as_update(before)

    peer = Y::Doc.new
    peer.apply_update(update)

    assert_equal "sent as a diff", peer.read_xml("root")
    assert_equal 1, peer.get_xml_text("root").xml_text_count
  end

  def test_attributes_accept_strings_numbers_and_nil
    doc = Y::Doc.new
    block = doc.get_xml_text("root").push_xml_text({})
    block.set_attribute("__type", "paragraph")
    block.set_attribute("__format", 0)
    block.set_attribute("__dir", nil)
    block.insert_embed(0, TEXT)
    block.insert(1, "typed")

    assert_equal "typed", doc.read_xml("root")
  end

  def test_a_stale_block_handle_is_a_no_op_not_an_error
    doc = Y::Doc.new
    root = doc.get_xml_text("root")
    missing = root.xml_text(5)

    assert_equal "", missing.to_s
    assert_equal 0, missing.length
    assert_raises(Y::Error) { missing.insert(0, "x") }
  end
end
