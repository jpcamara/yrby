# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# Interop tests between yrby, Y.js, and yrs
# These tests verify that all three implementations can communicate properly
class InteropTest < Minitest::Test
  # Resolve bun from the standard install location or PATH.
  BUN_PATH = [File.expand_path("~/.bun/bin/bun"), `command -v bun 2>/dev/null`.strip]
             .find { |p| !p.empty? && File.exist?(p) }
  YJS_GENERATOR = File.expand_path("fixtures/yjs_generator.mjs", __dir__)
  YRS_GENERATOR_DIR = File.expand_path("fixtures/yrs_generator", __dir__)
  YRS_GENERATOR = File.join(YRS_GENERATOR_DIR, "target/release/yrs_generator")

  # These tests cross-check byte compatibility with the real Y.js and yrs
  # implementations, so they need external tooling (bun + Y.js, and a built
  # yrs_generator). When that tooling isn't present they're skipped rather than
  # failed, so `rake test` is green anywhere; they run locally and in any CI job
  # that installs the tooling.
  def setup
    skip "bun not found (install bun to run interop tests)" unless BUN_PATH

    return if File.exist?(YRS_GENERATOR)

    if File.exist?(File.join(YRS_GENERATOR_DIR, "Cargo.toml"))
      system("cd #{YRS_GENERATOR_DIR} && cargo build --release 2>/dev/null")
    end
    skip "yrs_generator not built; skipping interop tests" unless File.exist?(YRS_GENERATOR)
  end

  def yjs(*args)
    stdout, stderr, status = Open3.capture3(BUN_PATH, "run", YJS_GENERATOR, *args.map(&:to_s))
    raise "yjs_generator failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def yrs(*args)
    stdout, status = Open3.capture2(YRS_GENERATOR, *args.map(&:to_s))
    raise "yrs_generator failed: #{stdout}" unless status.success?

    JSON.parse(stdout)
  end

  def b64_decode(str)
    str.unpack1("m0")
  end

  def b64_encode(str)
    [str].pack("m0")
  end

  # ============================================================================
  # Y.js -> yrby tests
  # ============================================================================

  def test_yjs_update_applied_to_y_ruby
    result = yjs("create-doc", 1, "content", "hello from yjs")

    doc = Y::Doc.new
    doc.apply_update(b64_decode(result["update"]))

    # State vectors should be semantically equivalent
    # (byte order may differ, but clocks should match)
    assert_equal b64_decode(result["state_vector"]).bytesize, doc.encode_state_vector.bytesize
  end

  def test_yjs_empty_doc_matches_y_ruby
    result = yjs("empty-doc", 1)

    doc = Y::Doc.new

    assert_equal b64_decode(result["state_vector"]), doc.encode_state_vector
  end

  def test_y_ruby_can_read_yjs_merged_docs
    doc1 = yjs("create-doc", 1, "content", "from doc1")
    doc2 = yjs("create-doc", 2, "content", "from doc2")

    merged = yjs("merge-updates", doc1["update"], doc2["update"])

    # yrby should be able to apply the merged update
    doc = Y::Doc.new
    doc.apply_update(b64_decode(merged["merged_update"]))

    # Verify it has content from both (state vector size > empty)
    empty_sv_size = b64_decode(yjs("empty-doc")["state_vector"]).bytesize

    assert_operator doc.encode_state_vector.bytesize, :>, empty_sv_size
  end

  # ============================================================================
  # yrby -> Y.js tests
  # ============================================================================

  def test_y_ruby_update_applied_to_yjs
    # Create a doc in yrby with Y.js update, then export and verify Y.js can read it
    yjs_doc = yjs("create-doc", 1, "content", "test content")

    # Load into yrby
    doc = Y::Doc.new
    doc.apply_update(b64_decode(yjs_doc["update"]))

    # Export from yrby
    update = b64_encode(doc.encode_state_as_update)

    # Y.js should be able to apply it
    result = yjs("apply-update", update)

    assert result["state_vector"]

    # Verify content is preserved
    text_result = yjs("get-text", update, "content")

    assert_equal "test content", text_result["content"]
  end

  def test_y_ruby_empty_doc_matches_yjs
    doc = Y::Doc.new
    update = b64_encode(doc.encode_state_as_update)

    result = yjs("apply-update", update)

    assert result["state_vector"]
  end

  # ============================================================================
  # yrs -> yrby tests
  # ============================================================================

  def test_yrs_update_applied_to_y_ruby
    result = yrs("create-doc", 1, "content", "hello from yrs")

    doc = Y::Doc.new
    doc.apply_update(b64_decode(result["update"]))

    # State vectors should match exactly (same implementation)
    assert_equal b64_decode(result["state_vector"]), doc.encode_state_vector
  end

  def test_yrs_empty_doc_matches_y_ruby
    result = yrs("empty-doc", 1)

    doc = Y::Doc.new

    assert_equal b64_decode(result["state_vector"]), doc.encode_state_vector
  end

  def test_y_ruby_can_read_yrs_merged_docs
    doc1 = yrs("create-doc", 1, "content", "from doc1")
    doc2 = yrs("create-doc", 2, "content", "from doc2")

    merged = yrs("merge-updates", doc1["update"], doc2["update"])

    doc = Y::Doc.new
    doc.apply_update(b64_decode(merged["merged_update"]))

    # State vectors should match exactly
    assert_equal b64_decode(merged["state_vector"]), doc.encode_state_vector
  end

  # ============================================================================
  # yrby -> yrs tests
  # ============================================================================

  def test_y_ruby_update_applied_to_yrs
    yrs_doc = yrs("create-doc", 1, "content", "test content")

    doc = Y::Doc.new
    doc.apply_update(b64_decode(yrs_doc["update"]))

    update = b64_encode(doc.encode_state_as_update)

    result = yrs("apply-update", update)

    assert result["state_vector"]

    text_result = yrs("get-text", update, "content")

    assert_equal "test content", text_result["content"]
  end

  # ============================================================================
  # Y.js <-> yrs cross-tests (via yrby)
  # ============================================================================

  def test_yjs_to_yrs_via_y_ruby
    # Create doc in Y.js
    yjs_doc = yjs("create-doc", 1, "content", "cross-platform test")

    # Load into yrby
    doc = Y::Doc.new
    doc.apply_update(b64_decode(yjs_doc["update"]))

    # Export and load into yrs
    update = b64_encode(doc.encode_state_as_update)
    yrs_result = yrs("get-text", update, "content")

    assert_equal "cross-platform test", yrs_result["content"]
  end

  def test_yrs_to_yjs_via_y_ruby
    # Create doc in yrs
    yrs_doc = yrs("create-doc", 1, "content", "rust to js test")

    # Load into yrby
    doc = Y::Doc.new
    doc.apply_update(b64_decode(yrs_doc["update"]))

    # Export and load into Y.js
    update = b64_encode(doc.encode_state_as_update)
    yjs_result = yjs("get-text", update, "content")

    assert_equal "rust to js test", yjs_result["content"]
  end

  # ============================================================================
  # Sync protocol tests
  # ============================================================================

  def test_sync_protocol_yjs_initiates_y_ruby_responds
    # Y.js has content
    yjs_doc = yjs("create-doc", 1, "content", "sync test")

    # yrby is empty
    doc = Y::Doc.new

    # yrby sends sync step 1 (its state vector)
    sv = b64_encode(doc.encode_state_vector)

    # Y.js computes diff
    diff = yjs("diff-update", yjs_doc["update"], sv)

    # yrby applies the diff
    doc.apply_update(b64_decode(diff["diff_update"]))

    # Verify yrby now has the content
    update = b64_encode(doc.encode_state_as_update)
    text = yjs("get-text", update, "content")

    assert_equal "sync test", text["content"]
  end

  def test_sync_protocol_y_ruby_initiates_yrs_responds
    # yrs has content
    yrs_doc = yrs("create-doc", 1, "content", "yrs sync test")

    # yrby is empty
    doc = Y::Doc.new

    # yrby sends its state vector
    sv = b64_encode(doc.encode_state_vector)

    # yrs computes diff
    diff = yrs("diff-update", yrs_doc["update"], sv)

    # yrby applies the diff
    doc.apply_update(b64_decode(diff["diff_update"]))

    # State vectors should now match
    assert_equal b64_decode(yrs_doc["state_vector"]), doc.encode_state_vector
  end

  def test_bidirectional_sync_yjs_and_y_ruby
    # Both have different content
    yjs_doc = yjs("create-doc", 1, "doc1", "yjs content")

    doc = Y::Doc.new
    doc.apply_update(b64_decode(yjs("create-doc", 2, "doc2", "yrb content")["update"]))

    # Exchange state vectors and updates
    yrb_sv = b64_encode(doc.encode_state_vector)
    yjs_sv = yjs_doc["state_vector"]

    # Y.js sends update for what yrby is missing
    yjs_to_yrb = yjs("diff-update", yjs_doc["update"], yrb_sv)

    # yrby sends update for what Y.js is missing
    yrb_update = b64_encode(doc.encode_state_as_update(b64_decode(yjs_sv)))

    # Apply updates
    doc.apply_update(b64_decode(yjs_to_yrb["diff_update"]))
    yjs_merged = yjs("apply-update", yrb_update, 1)

    # Now verify both have both contents
    yrb_final_update = b64_encode(doc.encode_state_as_update)

    # Check yrby has Y.js content
    doc1_text = yjs("get-text", yrb_final_update, "doc1")

    assert_equal "yjs content", doc1_text["content"]

    # Check Y.js has yrby content
    doc2_text = yjs("get-text", yjs_merged["update"], "doc2")

    assert_equal "yrb content", doc2_text["content"]
  end
end
