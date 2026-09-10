# frozen_string_literal: true

require "test_helper"

# Live Y::Text handles. The operation that matters is push: an agent streaming
# output appends over and over, and each append is a CRDT insert rather than a
# whole-document write, so a person typing in the same text keeps their edit.
class TextTest < Minitest::Test
  def setup
    @doc = Y::Doc.new
    @body = @doc.get_text("body")
  end

  def test_a_fresh_text_is_empty
    assert_equal "", @body.to_s
    assert_equal 0, @body.length
    assert_predicate @body, :empty?
  end

  def test_push_appends_and_returns_the_chunk
    assert_equal "hello", @body.push("hello")
    @body << " world"

    assert_equal "hello world", @body.to_s
    assert_equal 11, @body.size
  end

  def test_streaming_many_small_chunks_builds_one_string
    %w[The agent wrote this].each { |w| @body << "#{w} " }

    assert_equal "The agent wrote this ", @body.to_s
  end

  def test_insert_places_at_an_index
    @body.push("hello world")
    @body.insert(5, ",")

    assert_equal "hello, world", @body.to_s
  end

  def test_insert_clamps_rather_than_raising
    @body.push("abc")
    @body.insert(99, "!")

    assert_equal "abc!", @body.to_s

    @body.insert(-100, ">")

    assert_equal ">abc!", @body.to_s
  end

  def test_delete_removes_a_range_and_clamps
    @body.push("hello world")
    @body.delete(5, 6)

    assert_equal "hello", @body.to_s

    @body.delete(3, 999) # past the end removes what is there

    assert_equal "hel", @body.to_s
  end

  def test_clear_empties_the_text
    @body.push("something")
    @body.clear

    assert_predicate @body, :empty?
  end

  def test_reads_are_visible_to_the_read_only_snapshot
    @body.push("written from Ruby")

    assert_equal "written from Ruby", @doc.read_text("body")
  end

  def test_writes_sync_to_a_peer
    other = Y::Doc.new
    @body.push("from the agent")
    other.apply_update(@doc.encode_state_as_update)

    assert_equal "from the agent", other.get_text("body").to_s
  end

  # Two writers appending to the same text converge with both contributions
  # intact. This is the property the whole handle exists to preserve.
  def test_concurrent_appends_from_two_peers_both_survive
    other = Y::Doc.new
    other.apply_update(@doc.encode_state_as_update)

    @body.push("human ")
    other.get_text("body").push("agent ")

    @doc.apply_update(other.encode_state_as_update(@doc.encode_state_vector))
    other.apply_update(@doc.encode_state_as_update(other.encode_state_vector))

    assert_equal @body.to_s, other.get_text("body").to_s
    assert_includes @body.to_s, "human"
    assert_includes @body.to_s, "agent"
  end
end
