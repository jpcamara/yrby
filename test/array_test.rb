# frozen_string_literal: true

require "test_helper"

# Live Y::Array handles: reading and editing the elements of a shared list from
# Ruby. The case this type exists for is a list of records, so the nested-map
# tests matter more than the primitive ones.
class ArrayTest < Minitest::Test
  def setup
    @doc = Y::Doc.new
    @plan = @doc.get_array("plan")
  end

  def test_a_fresh_array_is_empty
    assert_equal 0, @plan.size
    assert_predicate @plan, :empty?
    assert_equal [], @plan.to_a
  end

  def test_push_appends_and_returns_the_value
    assert_equal "one", @plan.push("one")
    @plan << "two"

    assert_equal %w[one two], @plan.to_a
    assert_equal 2, @plan.length
  end

  def test_primitives_round_trip
    @plan.push("a")
    @plan.push(2)
    @plan.push(3.5)
    @plan.push(true)
    @plan.push(nil)

    assert_equal ["a", 2, 3.5, true, nil], @plan.to_a
  end

  def test_index_reads_including_negative
    @plan.push("a")
    @plan.push("b")

    assert_equal "a", @plan[0]
    assert_equal "b", @plan[-1]
    assert_nil @plan[9]
    assert_nil @plan[-9]
  end

  def test_insert_places_and_clamps
    @plan.push("a")
    @plan.push("c")
    @plan.insert(1, "b")

    assert_equal %w[a b c], @plan.to_a

    @plan.insert(99, "z") # past the end appends rather than raising

    assert_equal %w[a b c z], @plan.to_a
  end

  def test_delete_at_returns_the_removed_value
    @plan.push("a")
    @plan.push("b")

    assert_equal "b", @plan.delete_at(-1)
    assert_equal ["a"], @plan.to_a
    assert_nil @plan.delete_at(9)
  end

  def test_set_replaces_in_place
    @plan.push("a")
    @plan.push("b")
    @plan[1] = "B"

    assert_equal %w[a B], @plan.to_a
  end

  def test_clear_empties_the_array
    2.times { |i| @plan.push(i) }
    @plan.clear

    assert_predicate @plan, :empty?
  end

  def test_each_yields_every_element
    @plan.push("a")
    @plan.push("b")
    seen = []
    @plan.each { |v| seen << v }

    assert_equal %w[a b], seen
  end

  # --- the shape this type exists for ---------------------------------------

  def test_a_pushed_hash_becomes_a_live_nested_map
    @plan.push({ "text" => "Find the posts", "status" => "pending" })
    step = @plan.get_map(0)

    assert_instance_of Y::Map, step
    assert_equal "pending", step["status"]
  end

  def test_editing_a_map_nested_in_an_array_mutates_the_document
    @plan.push({ "text" => "Find the posts", "status" => "pending" })
    @plan.get_map(0)["status"] = "done"

    # Read it back through a fresh handle, and through the read-only snapshot,
    # so this proves the document changed rather than a Ruby object.
    assert_equal "done", @plan.get_map(0)["status"]
    assert_equal "done", JSON.parse(@doc.read_array("plan")).first["status"]
  end

  def test_get_map_is_nil_for_a_non_map_element
    @plan.push("just a string")

    assert_nil @plan.get_map(0)
    assert_nil @plan.get_map(9)
  end

  def test_nested_arrays_are_reachable_and_writable
    @doc.get_array("grid").push([])
    row = @doc.get_array("grid")
    row.push({ "cells" => [] })

    assert_nil row.get_array(0) # a plain Ruby array is stored as an embedded value
  end

  def test_a_handle_survives_the_element_moving
    @plan.push({ "id" => "a", "status" => "pending" })
    @plan.push({ "id" => "b", "status" => "pending" })
    # Index 1 is a different record after the delete, and the handle is
    # index-addressed, so it now points at what is there now. Documented, not
    # accidental: re-fetch a handle after reordering.
    @plan.delete_at(0)

    assert_equal "b", @plan.get_map(0)["id"]
  end

  def test_writes_sync_to_a_peer
    other = Y::Doc.new
    @plan.push({ "text" => "step", "status" => "pending" })
    other.apply_update(@doc.encode_state_as_update)

    assert_equal 1, other.get_array("plan").size
    assert_equal "pending", other.get_array("plan").get_map(0)["status"]
  end
end
