# frozen_string_literal: true

require "test_helper"

# apply_update_changes applies an update and says which top-level blocks it
# touched, so a process following a document can react to the part that
# changed instead of diffing the whole text.
class DocChangesTest < Minitest::Test
  def setup
    @src = Y::Doc.new
    Y::Lexxy.append_paragraph(@src, "one")
    Y::Lexxy.append_paragraph(@src, "two")
    Y::Lexxy.append_list(@src, %w[a b])
    @peer = Y::Doc.new
    @peer.apply_update(@src.encode_state_as_update)
  end

  def test_an_edit_inside_a_block_names_that_block
    update = @src.diff { @src.get_xml_text("root").xml_text(1).insert(4, " more") }

    assert_equal [1], @peer.apply_update_changes(update, "root")
    assert_equal "one\ntwo more\na\nb", @peer.read_xml("root")
  end

  def test_an_edit_deep_inside_a_list_names_the_list
    update = @src.diff { @src.get_xml_text("root").xml_text(2).xml_text(1).insert(2, "!") }

    assert_equal [2], @peer.apply_update_changes(update, "root")
  end

  def test_a_block_added_or_inserted_names_its_ordinal
    appended = @src.diff { Y::Lexxy.append_paragraph(@src, "three") }

    assert_equal [3], @peer.apply_update_changes(appended, "root")

    inserted = @src.diff { Y::Lexical.insert_paragraph(@src, 1, "between") }

    assert_equal [1], @peer.apply_update_changes(inserted, "root")
    assert_equal "one\nbetween\ntwo\na\nb\nthree", @peer.read_xml("root")
  end

  def test_a_block_removed_names_the_ordinal_it_had
    update = @src.diff { @src.get_xml_text("root").delete_xml_text(0) }

    assert_equal [0], @peer.apply_update_changes(update, "root")
    assert_equal "two\na\nb", @peer.read_xml("root")
  end

  def test_an_update_already_applied_changes_nothing
    update = @src.diff { Y::Lexxy.append_paragraph(@src, "three") }
    @peer.apply_update_changes(update, "root")

    assert_empty @peer.apply_update_changes(update, "root")
  end
end
