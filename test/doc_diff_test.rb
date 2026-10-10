# frozen_string_literal: true

require "test_helper"

# Doc#diff is the unit a long-lived process records and broadcasts as it
# streams into a document: the update the block produced, or nil for none.
class DocDiffTest < Minitest::Test
  def test_the_update_the_block_produced_applies_on_a_peer
    doc = Y::Doc.new
    Y::Lexical.append_paragraph(doc, "before")
    peer = Y::Doc.new
    peer.apply_update(doc.encode_state_as_update)

    update = doc.diff { |d| Y::Lexical.append_paragraph(d, "streamed") }
    peer.apply_update(update)

    assert_equal "before\nstreamed", peer.read_xml("root")
  end

  def test_a_block_that_changes_nothing_yields_nil
    doc = Y::Doc.new

    assert_nil(doc.diff { |d| d.get_text("content") })
  end

  def test_successive_diffs_carry_only_their_own_chunk
    doc = Y::Doc.new
    block = nil
    setup = doc.diff { |d| block = Y::Lexical.append_paragraph(d, "") }
    first = doc.diff { block.insert(block.length, "one ") }
    second = doc.diff { block.insert(block.length, "two") }

    peer = Y::Doc.new
    [setup, first, second].each { |update| peer.apply_update(update) }

    assert_equal "one two", peer.read_xml("root")
    assert_operator second.bytesize, :<, doc.encode_state_as_update.bytesize,
                    "a diff is about its chunk, not the document"
  end
end
