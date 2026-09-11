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

  def test_a_list_renders_like_a_typed_one
    doc = Y::Doc.new
    Y::Lexxy.append_list(doc, %w[alpha beta])
    Y::Lexxy.append_list(doc, %w[one two], ordered: true)

    # The exact HTML the renderer produces for the same lists typed in Lexxy.
    assert_equal "<ul><li value=\"1\">alpha</li><li value=\"2\">beta</li></ul>" \
                 "<ol><li value=\"1\">one</li><li value=\"2\">two</li></ol>", Y::Lexxy.new(doc).to_html("root")
  end

  def test_a_vanilla_lexical_list_uses_the_standard_item_type
    doc = Y::Doc.new
    list = Y::Lexical.append_list(doc, %w[x y])

    assert_equal 2, list.xml_text_count
    assert_includes list.xml_text(1).to_s, "y"
    assert_equal "<ul><li value=\"1\">x</li><li value=\"2\">y</li></ul>", Y::Lexical.new(doc).to_html("root")
  end

  def test_a_list_round_trips_to_a_peer
    doc = Y::Doc.new
    Y::Lexxy.append_list(doc, %w[alpha beta])
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    assert_equal "alpha\nbeta", peer.read_xml("root")
  end

  def test_text_is_the_block_without_its_markers
    doc = Y::Doc.new
    Y::Lexxy.append_paragraph(doc, ["plain ", { text: "bold", bold: true }])
    Y::Lexxy.append_list(doc, %w[first second])
    root = doc.get_xml_text("root")

    assert_equal "plain bold", root.xml_text(0).text
    assert_equal "first\nsecond", root.xml_text(1).text
    assert_equal "second", root.xml_text(1).xml_text(1).text
  end

  # --- editing in place ---

  def test_blocks_can_be_inserted_between_replaced_and_removed
    doc = Y::Doc.new
    %w[one two three].each { |s| Y::Lexical.append_paragraph(doc, s) }
    Y::Lexical.insert_paragraph(doc, 1, "between")

    assert_equal "one\nbetween\ntwo\nthree", doc.read_xml("root")

    Y::Lexical.replace_runs(doc.get_xml_text("root").xml_text(1), [{ text: "BETWEEN", bold: true }])

    assert Y::Lexical.delete_block(doc, 0)
    refute Y::Lexical.delete_block(doc, 99)

    assert_equal "BETWEEN\ntwo\nthree", doc.read_xml("root")
    assert_equal "<p><strong>BETWEEN</strong></p><p>two</p><p>three</p>", Y::Lexical.new(doc).to_html("root")
  end

  def test_text_inside_a_block_can_be_deleted_and_cleared
    doc = Y::Doc.new
    block = Y::Lexical.append_paragraph(doc, "hello world")
    block.delete(6, 6) # "hello "; index 0 is the text node's marker

    assert_equal "hello", doc.read_xml("root")

    block.clear

    assert_equal 0, block.length
  end

  # --- formatting: what Ruby writes renders like what a person typed ---

  def test_formatted_runs_render_like_typed_ones
    doc = Y::Doc.new
    Y::Lexxy.append_paragraph(doc, ["plain ", { text: "bold", bold: true }, " ", { text: "italic", italic: true }, " ",
                                    { text: "struck", strikethrough: true }, " ", { text: "under", underline: true }])

    assert_equal "<p>plain <strong>bold</strong> <em>italic</em> <s>struck</s> <u>under</u></p>",
                 Y::Lexxy.new(doc).to_html("root")
  end

  def test_links_code_and_quotes_render_like_typed_ones
    doc = Y::Doc.new
    Y::Lexxy.append_paragraph(doc, ["see the ", { text: "docs", link: "https://example.com/docs" }, " here"])
    Y::Lexxy.append_quote(doc, "a quoted line")
    Y::Lexxy.append_code(doc, "puts 1")

    assert_equal "<p>see the <a href=\"https://example.com/docs\">docs</a> here</p>" \
                 "<blockquote><p>a quoted line</p></blockquote><pre data-language=\"plain\">puts 1</pre>",
                 Y::Lexxy.new(doc).to_html("root")
  end

  def test_markdown_becomes_lexical_blocks
    md = "## Agent review\n\nReads **clearly**, every step has an *owner*. " \
         "See the [runbook](https://x.io/r).\n\n" \
         "- Name who signs off.\n- Add a `rollback` step.\n\n> One thought.\n\n" \
         "```ruby\nputs 1\n```\n1. first\n2. second\n"
    doc = Y::Doc.new
    Y::Lexxy.append_markdown(doc, md)

    expected = "<h2>Agent review</h2>" \
               "<p>Reads <strong>clearly</strong>, every step has an <em>owner</em>. " \
               "See the <a href=\"https://x.io/r\">runbook</a>.</p>" \
               "<ul><li value=\"1\">Name who signs off.</li>" \
               "<li value=\"2\">Add a <code>rollback</code> step.</li></ul>" \
               "<blockquote><p>One thought.</p></blockquote>" \
               "<pre data-language=\"ruby\">puts 1</pre>" \
               "<ol><li value=\"1\">first</li><li value=\"2\">second</li></ol>"

    assert_equal expected, Y::Lexxy.new(doc).to_html("root")
  end

  # A caret is a Yjs relative position: {type, tname, item, assoc}. Inside a
  # text it names the character to the right; at the end of a block it names
  # the block; at a root it names the root. Ids are global, so a position
  # built here resolves on every peer.
  def test_a_position_inside_text_names_the_character
    doc = Y::Doc.new
    block = Y::Lexical.append_paragraph(doc, "Hello caret world")
    pos = block.relative_position(6) # after the marker embed, after "Hello"

    assert_kind_of Integer, pos["item"]["client"]
    assert_kind_of Integer, pos["item"]["clock"]
    assert_nil pos["type"]
    assert_nil pos["tname"]
    assert_equal 0, pos["assoc"]
  end

  def test_a_position_at_the_end_of_a_block_names_the_block
    doc = Y::Doc.new
    block = Y::Lexical.append_paragraph(doc, "Hello caret world")
    pos = block.relative_position(block.length)

    assert_nil pos["item"]
    assert_kind_of Integer, pos["type"]["clock"]
    assert_equal 0, pos["assoc"]
  end

  def test_a_position_at_a_root_names_the_root
    pos = Y::Doc.new.get_xml_text("root").relative_position(0)

    assert_equal "root", pos["tname"]
    assert_nil pos["item"]
    assert_nil pos["type"]
  end

  def test_before_association_and_peers_agree_on_a_position
    doc = Y::Doc.new
    block = Y::Lexical.append_paragraph(doc, "Hello caret world")
    before = block.relative_position(6, assoc: :before)
    after = block.relative_position(6)

    assert_equal(-1, before["assoc"])
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    assert_equal after, peer.get_xml_text("root").xml_text(0).relative_position(6)
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
