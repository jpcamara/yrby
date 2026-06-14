# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"

class ProseMirrorTest < Minitest::Test
  # Expected structure of the ProseMirrorDoc fixture:
  #   heading(level: "1") > "Title"
  #   paragraph > "Hello " + bold("bold") + " and a " + link("link", https://example.com)

  def test_extract_from_update
    result = YrbLite::ProseMirrorExtractor.extract(YjsFixtures::ProseMirrorDoc::UPDATE)

    assert_equal "doc", result["type"]
    assert_equal 2, result["content"].length

    heading, paragraph = result["content"]

    assert_equal "heading", heading["type"]
    assert_equal({ "level" => "1" }, heading["attrs"])
    assert_equal [{ "type" => "text", "text" => "Title" }], heading["content"]

    assert_equal "paragraph", paragraph["type"]
    runs = paragraph["content"]
    assert_equal 4, runs.length

    assert_equal({ "type" => "text", "text" => "Hello " }, runs[0])
    assert_equal "bold", runs[1]["text"]
    assert_equal [{ "type" => "bold" }], runs[1]["marks"]
    assert_equal({ "type" => "text", "text" => " and a " }, runs[2])
    assert_equal "link", runs[3]["text"]
    assert_equal(
      [{ "type" => "link", "attrs" => { "href" => "https://example.com" } }],
      runs[3]["marks"]
    )
  end

  def test_extract_from_doc
    doc = YrbLite::Doc.new
    doc.apply_update(YjsFixtures::ProseMirrorDoc::UPDATE)

    result = YrbLite::ProseMirrorExtractor.extract_from_doc(doc)

    assert_equal "doc", result["type"]
    assert_equal %w[heading paragraph], result["content"].map { |n| n["type"] }
  end

  def test_extract_with_explicit_fragment_name
    result = YrbLite::ProseMirrorExtractor.extract(
      YjsFixtures::ProseMirrorDoc::UPDATE, fragment: "prosemirror"
    )
    assert_equal "doc", result["type"]
  end

  def test_extract_with_missing_fragment_name_raises
    error = assert_raises(RuntimeError) do
      YrbLite::ProseMirrorExtractor.extract(
        YjsFixtures::ProseMirrorDoc::UPDATE, fragment: "nope"
      )
    end
    assert_match(/No XML fragment named/, error.message)
  end

  def test_extract_from_empty_doc_raises
    error = assert_raises(RuntimeError) do
      YrbLite::ProseMirrorExtractor.extract(YjsFixtures::EmptyDoc::UPDATE)
    end
    assert_match(/No ProseMirror content found/, error.message)
  end

  def test_extract_invalid_update_raises
    assert_raises(RuntimeError) do
      YrbLite::ProseMirrorExtractor.extract("not a real update")
    end
  end

  def test_doc_prosemirror_json_returns_string
    doc = YrbLite::Doc.new
    doc.apply_update(YjsFixtures::ProseMirrorDoc::UPDATE)

    json = doc.prosemirror_json
    assert_kind_of String, json
    assert_equal "doc", JSON.parse(json)["type"]
  end
end
