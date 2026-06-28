# frozen_string_literal: true

require "test_helper"
require "y/decoder"
require "base64"
require "json"

# Decoder coverage across the major editors' Yjs storage shapes. The fixtures are
# real CRDT states captured from each encoder:
#   - LEXICAL:     @lexical/yjs (headless) -- two paragraphs, the 2nd ending bold.
#   - PROSEMIRROR: the y-prosemirror / TipTap shape (Y.XmlFragment of block
#                  Y.XmlElements) -- an <h1> then a paragraph "Plain and **bold**".
#   - PLAINTEXT:   a plain Y.Text "content".
# (Regenerate via packages/y-ruby-decode, which carries the encoder deps.)
class DecoderTest < Minitest::Test
  # rubocop:disable Layout/LineLength -- opaque base64 CRDT fixtures, can't wrap
  LEXICAL = "ASXk3uf5CgAHAQRyb290BigA5N7n+QoABl9fdHlwZQF3CXBhcmFncmFwaCgA5N7n+QoACF9fZm9ybWF0AX0AKADk3uf5CgAHX19zdHlsZQF3ACgA5N7n+QoACF9faW5kZW50AX0AKADk3uf5CgAFX19kaXIBfigA5N7n+QoADF9fdGV4dEZvcm1hdAF9ACgA5N7n+QoAC19fdGV4dFN0eWxlAXcABwDk3uf5CgABKADk3uf5CggGX190eXBlAXcEdGV4dCgA5N7n+QoICF9fZm9ybWF0AX0AKADk3uf5CggHX19zdHlsZQF3ACgA5N7n+QoIBl9fbW9kZQF9ACgA5N7n+QoICF9fZGV0YWlsAX0AhOTe5/kKCBJIZWxsbyBmcm9tIExleGljYWyH5N7n+QoABigA5N7n+QogBl9fdHlwZQF3CXBhcmFncmFwaCgA5N7n+QogCF9fZm9ybWF0AX0AKADk3uf5CiAHX19zdHlsZQF3ACgA5N7n+QogCF9faW5kZW50AX0AKADk3uf5CiAFX19kaXIBfigA5N7n+QogDF9fdGV4dEZvcm1hdAF9ACgA5N7n+QogC19fdGV4dFN0eWxlAXcABwDk3uf5CiABKADk3uf5CigGX190eXBlAXcEdGV4dCgA5N7n+QooCF9fZm9ybWF0AX0AKADk3uf5CigHX19zdHlsZQF3ACgA5N7n+QooBl9fbW9kZQF9ACgA5N7n+QooCF9fZGV0YWlsAX0AhOTe5/kKKAdzZWNvbmQgh+Te5/kKNAEoAOTe5/kKNQZfX3R5cGUBdwR0ZXh0KADk3uf5CjUIX19mb3JtYXQBfQEoAOTe5/kKNQdfX3N0eWxlAXcAKADk3uf5CjUGX19tb2RlAX0AKADk3uf5CjUIX19kZXRhaWwBfQCE5N7n+Qo1BGJvbGQA"

  PROSEMIRROR = "AQr12Z2xBQAHAQdkZWZhdWx0AwdoZWFkaW5nKAD12Z2xBQAFbGV2ZWwBdwExh/XZnbEFAAMJcGFyYWdyYXBoBwD12Z2xBQAGBAD12Z2xBQMQQSBUaXBUYXAgSGVhZGluZwcA9dmdsQUCBgQA9dmdsQUUClBsYWluIGFuZCCG9dmdsQUeBGJvbGQEdHJ1ZYT12Z2xBR8EYm9sZIb12Z2xBSMEYm9sZARudWxsAA=="

  PLAINTEXT = "AQHhwvm8AgAEAQdjb250ZW50D2p1c3QgcGxhaW4gdGV4dAA="

  # A Y.Map "state" = { title: "Dashboard", count: 3, active: true, price: 9.99 }.
  MAP = "AQSP+KW4BQAoAQVzdGF0ZQV0aXRsZQF3CURhc2hib2FyZCgBBXN0YXRlBWNvdW50AX0DKAEFc3RhdGUGYWN0aXZlAXgoAQVzdGF0ZQVwcmljZQF7QCP64UeuFHsA"
  # rubocop:enable Layout/LineLength

  def decode(b64)
    Base64.strict_decode64(b64)
  end

  # --- Lexical / Lexxy -------------------------------------------------------

  def test_lexical_blocks_are_separated_by_newlines
    assert_equal "Hello from Lexical\nsecond bold", Y::Decoder.text(decode(LEXICAL))
  end

  def test_lexical_paragraphs_do_not_merge_into_one_run
    # Regression: Lexical's blocks are sibling Y.XmlText nodes with no element
    # tags, so a flat read glued them ("...Lexicalsecond...") and broke word
    # boundaries for search. read_xml now joins top-level blocks with newlines.
    refute_includes Y::Decoder.text(decode(LEXICAL)), "Lexicalsecond"
  end

  # --- ProseMirror / TipTap --------------------------------------------------

  def test_prosemirror_strips_tags_and_separates_blocks
    assert_equal "A TipTap Heading\nPlain and bold", Y::Decoder.text(decode(PROSEMIRROR))
  end

  # --- plain Y.Text ----------------------------------------------------------

  def test_plain_text
    assert_equal "just plain text", Y::Decoder.text(decode(PLAINTEXT))
  end

  # --- preview / field / edges ----------------------------------------------

  def test_preview_collapses_to_one_line_and_truncates
    assert_equal "Hello from Lexical second bold", Y::Decoder.preview(decode(LEXICAL))
    assert_equal "A Ti…", Y::Decoder.preview(decode(PROSEMIRROR), limit: 4)
  end

  def test_field_pins_the_root
    assert_equal "just plain text", Y::Decoder.text(decode(PLAINTEXT), field: "content")
    assert_equal "", Y::Decoder.text(decode(PLAINTEXT), field: "no-such-root")
  end

  def test_empty_document_is_blank
    assert_equal "", Y::Decoder.text(Y::Doc.new.encode_state_as_update)
  end

  # --- native Doc readers underneath ----------------------------------------

  def test_doc_readers_cover_each_shape
    assert_equal ["root"], Y::Decoder.load(decode(LEXICAL)).root_names
    # Lexical/ProseMirror roots aren't plain text, so read_text is empty there;
    # read_xml carries the block-separated content.
    assert_equal "", Y::Decoder.load(decode(LEXICAL)).read_text("root").to_s.strip
    assert_includes Y::Decoder.load(decode(LEXICAL)).read_xml("root"), "\n"
    assert_equal "just plain text", Y::Decoder.load(decode(PLAINTEXT)).read_text("content")
  end

  # --- read_map (structured state) ------------------------------------------

  def test_read_map_returns_state_as_json
    doc = Y::Doc.new
    doc.apply_update(decode(MAP))

    assert_equal(
      { "title" => "Dashboard", "count" => 3, "active" => true, "price" => 9.99 },
      JSON.parse(doc.read_map("state"))
    )
  end

  def test_read_map_missing_root_is_nil
    doc = Y::Doc.new
    doc.apply_update(decode(MAP))

    assert_nil doc.read_map("nope")
  end
end
