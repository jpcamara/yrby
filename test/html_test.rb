# frozen_string_literal: true

require "test_helper"

# Y::Lexical: schema-pinned rendering of Lexical/Lexxy documents. The class is
# named for the schema it understands — the Doc itself stays schema-agnostic.
# The reference pair under ext/yrby/src/fixtures was captured from one live
# Lexxy editor session: lexxy_full.bin is the synced Yjs state, lexxy_full.html
# is the editor's own `value` (the HTML a Lexxy form submits to Rails).
# to_html must reproduce it byte for byte — the schema mapping itself is
# exercised in the Rust tests.
class HtmlTest < Minitest::Test
  FIXTURES = File.expand_path("../ext/yrby/src/fixtures", __dir__)

  def lexical_for_fixture
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_full.bin")))
    Y::Lexical.new(doc)
  end

  def test_to_html_matches_lexxys_own_serializer_byte_for_byte
    expected = File.read(File.join(FIXTURES, "lexxy_full.html")).chomp

    assert_equal expected, lexical_for_fixture.to_html
    assert_equal expected, lexical_for_fixture.to_html("root"), "explicit root name"
  end

  def test_to_html_returns_nil_for_a_missing_root
    assert_nil Y::Lexical.new(Y::Doc.new).to_html("nope")
  end

  def test_to_html_reads_live_state
    doc = Y::Doc.new
    lexical = Y::Lexical.new(doc)

    assert_nil lexical.to_html, "no root yet"
    doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_full.bin")))

    assert_includes lexical.to_html, "<h1>Heading One</h1>",
                    "the view tracks the doc; no re-wrap needed after updates"
  end

  def test_to_html_covers_every_lexxy_node_type
    html = lexical_for_fixture.to_html

    # One structural probe per node family, so a regression names the node.
    {
      "headings" => "<h6>Heading H6</h6>",
      "bold+italic combo" => "<i><strong>bolditalic</strong></i>",
      "highlight" => "<mark>highlight</mark>",
      "escaping" => "&lt;escaped &amp; \"chars\"&gt;",
      "link" => '<a href="https://example.com/a?b=1&amp;c=2">the site</a>',
      "link title" => '<a href="https://ext.example.com" title="External">',
      "nested list" => '<li value="2" class="lexxy-nested-listitem">',
      "check list" => '<li aria-checked="true" value="1">Done item</li>',
      "quote" => "<blockquote>A quote about CRDTs.</blockquote>",
      "code block" => '<pre data-language="javascript">const x = 1;<br>console.log(x);</pre>',
      "code with tabs" => "<pre data-language=\"ruby\">def hello<br><span>\t</span>42<br>end</pre>",
      "divider" => "<hr>",
      "table" => '<figure class="lexxy-content__table-wrapper"><table><tbody>',
      "header cell" => '<th class="lexxy-content__table-cell--header"',
      "mention attachment" =>
        'sgid="SGID_MENTION_1" content="&lt;span class=&quot;mention&quot;&gt;@Alice&lt;/span&gt;"',
      "upload attachment" => 'filename="photo.png" filesize="12345" width="800" height="600" presentation="gallery"',
      "tab" => "<span>\t</span>after-tab",
      "empty paragraph" => "<p><br></p>"
    }.each do |what, snippet|
      assert_includes html, snippet, "#{what} did not render canonically"
    end
  end

  def test_to_html_matches_lexxy_on_the_torture_document
    # Second ground-truth pair (see lexical_html.rs for the full inventory):
    # blocks nested inside table cells, header-column/corner cells, five-level
    # mixed lists, formatted links in headings, the full format stack,
    # unicode, escape traps, whitespace-only paragraphs. Captured live from
    # Lexxy; byte-for-byte here proves the whole pipeline (bytes -> native
    # render -> Ruby string) reproduces Lexxy's own sanitized export.
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_torture.bin")))
    expected = File.read(File.join(FIXTURES, "lexxy_torture.html")).chomp

    assert_equal expected, Y::Lexical.new(doc).to_html
  end

  def test_read_text_extraction_survives_the_torture_document
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_torture.bin")))
    text = doc.read_xml("root")

    assert_includes text, "Level five", "deepest list level extracted"
    assert_includes text, "你好世界", "multibyte text extracted"
    assert_includes text, "@Dave", "mention inside a table cell extracted"
  end

  def test_read_text_extraction_includes_attachments
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_full.bin")))
    text = doc.read_xml("root")

    assert_includes text, "Mention: @Alice done.", "inline mention text"
    assert_includes text, "The team, 2026", "upload caption"
    refute_includes text, "UNDEFINED"
  end
end
