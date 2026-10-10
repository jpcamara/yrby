# frozen_string_literal: true

require "test_helper"
require "json"

# Live `Y::Map` handles: reading and writing the actual shared map, not just an
# opaque CRDT sync. A handle is addressed by root name + a path of keys and
# re-resolves per operation, so it never caches a raw yrs branch that could
# dangle when the tree is mutated (possibly on another thread). Every operation
# runs inside `nogvl`, matching `Y::Doc`'s thread-safety model.
class MapTest < Minitest::Test
  def setup
    @doc = Y::Doc.new
    @map = @doc.get_map("state")
  end

  # --- primitives round-trip ---

  def test_string_value
    @map["title"] = "Dashboard"

    assert_equal "Dashboard", @map["title"]
  end

  def test_integer_value
    @map["count"] = 42

    assert_equal 42, @map["count"]
  end

  def test_float_value
    @map["ratio"] = 1.5

    assert_in_delta 1.5, @map["ratio"]
  end

  def test_boolean_values
    @map["active"] = true
    @map["hidden"] = false

    assert @map["active"]
    refute @map["hidden"]
  end

  def test_nil_value
    @map["missing"] = nil

    assert_nil @map["missing"]
    assert @map.key?("missing"), "an explicit nil is still a present key"
  end

  def test_array_value
    @map["tags"] = %w[a b c]

    assert_equal %w[a b c], @map["tags"]
  end

  def test_nested_hash_snapshot
    @map["user"] = { "name" => "Ada", "role" => "eng" }

    assert_equal({ "name" => "Ada", "role" => "eng" }, @map["user"])
  end

  def test_symbol_keys_stringify
    @map[:mood] = "great"

    assert_equal "great", @map["mood"]
    assert @map.key?("mood")
  end

  # --- assignment returns the value (Ruby []= contract) ---

  def test_set_returns_assigned_value
    assert_equal "v", (@map["k"] = "v")
  end

  def test_set_alias_returns_value
    assert_equal 7, @map.set("k", 7)
  end

  # --- reads ---

  def test_missing_key_is_nil
    assert_nil @map["nope"]
    refute @map.key?("nope")
  end

  def test_size_and_length
    @map["a"] = 1
    @map["b"] = 2

    assert_equal 2, @map.size
    assert_equal 2, @map.length
  end

  def test_keys
    @map["a"] = 1
    @map["b"] = 2

    assert_equal %w[a b], @map.keys.sort
  end

  def test_to_h
    @map["a"] = 1
    @map["b"] = "two"

    assert_equal({ "a" => 1, "b" => "two" }, @map.to_h)
  end

  def test_each_yields_key_value
    @map["a"] = 1
    @map["b"] = 2
    seen = {}
    @map.each { |k, v| seen[k] = v }

    assert_equal({ "a" => 1, "b" => 2 }, seen)
  end

  # --- writes ---

  def test_delete_returns_previous_value
    @map["k"] = "v"

    assert_equal "v", @map.delete("k")
    refute @map.key?("k")
  end

  def test_delete_missing_is_nil
    assert_nil @map.delete("nope")
  end

  def test_clear
    @map["a"] = 1
    @map["b"] = 2
    @map.clear

    assert_equal 0, @map.size
    assert_empty @map.keys
  end

  def test_overwrite_value
    @map["k"] = "first"
    @map["k"] = "second"

    assert_equal "second", @map["k"]
    assert_equal 1, @map.size
  end

  # --- live nested maps ---

  def test_get_map_returns_live_handle
    @map["user"] = { "name" => "Ada" }
    user = @map.get_map("user")

    assert_instance_of Y::Map, user
    assert_equal "Ada", user["name"]
  end

  def test_nested_write_mutates_document
    @map["user"] = { "name" => "Ada" }
    user = @map.get_map("user")
    user["name"] = "Grace"
    user["role"] = "eng"

    # Reflected through a fresh snapshot of the parent and via read_map.
    assert_equal({ "name" => "Grace", "role" => "eng" }, @map["user"])
    parsed = JSON.parse(@doc.read_map("state"))

    assert_equal "Grace", parsed.dig("user", "name")
  end

  def test_get_map_on_non_map_is_nil
    @map["scalar"] = 5

    assert_nil @map.get_map("scalar")
  end

  def test_get_map_on_missing_is_nil
    assert_nil @map.get_map("nope")
  end

  def test_deeply_nested_maps
    @map["a"] = { "b" => { "c" => "deep" } }
    a = @map.get_map("a")
    b = a.get_map("b")

    assert_equal "deep", b["c"]
    b["c"] = "deeper"

    assert_equal "deeper", @doc.get_map("state").get_map("a").get_map("b")["c"]
  end

  def test_live_handle_survives_parent_reassignment
    # Re-resolution per op means a nested handle keeps working after the parent
    # map's other keys change around it.
    @map["user"] = { "name" => "Ada" }
    user = @map.get_map("user")
    @map["other"] = "x"
    user["name"] = "Grace"

    assert_equal "Grace", @map["user"]["name"]
  end

  # --- integration with the rest of the API ---

  def test_get_map_persists_root_across_calls
    @map["k"] = "v"

    assert_equal "v", @doc.get_map("state")["k"]
  end

  def test_read_map_reflects_handle_writes
    @map["title"] = "Dashboard"
    @map["count"] = 3

    assert_equal({ "count" => 3, "title" => "Dashboard" }, JSON.parse(@doc.read_map("state")))
  end

  def test_writes_propagate_over_sync
    @map["title"] = "Dashboard"
    @map["user"] = { "name" => "Ada" }

    peer = Y::Doc.new
    peer.apply_update(@doc.encode_state_as_update)

    peer_map = peer.get_map("state")

    assert_equal "Dashboard", peer_map["title"]
    assert_equal({ "name" => "Ada" }, peer_map["user"])
  end

  # --- thread safety ---

  def test_concurrent_writes_and_reads_on_shared_map
    threads = 8
    iterations = 100
    errors = Queue.new

    threads.times.map do |i|
      Thread.new do
        map = @doc.get_map("state")
        iterations.times do |n|
          if i.even?
            map["k#{i}"] = n
          else
            map.to_h
            map.keys
            map.size
          end
        end
      rescue StandardError => e
        errors << e
      end
    end.each(&:join)

    assert_empty errors, "concurrent access raised: #{errors.size} errors"
    # Each writer thread left its last value.
    (0...threads).select(&:even?).each do |i|
      assert_equal iterations - 1, @map["k#{i}"]
    end
  end
end
