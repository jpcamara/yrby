# frozen_string_literal: true

require "test_helper"

# Y::Tiptap: schema-pinned rendering of Tiptap documents (Y::ProseMirror, its
# base class, renders core ProseMirror; Y::Tiptap adds Tiptap's extension
# nodes as rules). The fixtures under ext/yrby/crates/prosemirror-html/src/fixtures were captured from
# a real Tiptap editor: prosemirror_tiptap.bin is the synced Yjs state,
# prosemirror_tiptap.html is the editor's own getHTML(). to_html reproduces it
# byte for byte. The core schema mapping is exercised in the Rust tests; the
# Tiptap-specific half is Y::Tiptap's rule set, so these fixture tests
# exercise the extension path end to end — they are the Tiptap byte-parity
# guarantee.
class ProseMirrorHtmlTest < Minitest::Test
  FIXTURES = File.expand_path("../ext/yrby/crates/prosemirror-html/src/fixtures", __dir__)

  def tiptap_for(name)
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "#{name}.bin")))
    Y::Tiptap.new(doc)
  end

  def test_to_html_matches_tiptaps_gethtml_byte_for_byte
    expected = File.read(File.join(FIXTURES, "prosemirror_tiptap.html"))

    assert_equal expected, tiptap_for("prosemirror_tiptap").to_html
    assert_equal expected, tiptap_for("prosemirror_tiptap").to_html("default"),
                 "explicit root name"
  end

  def test_to_html_renders_a_semantic_table
    expected = File.read(File.join(FIXTURES, "prosemirror_table.html"))

    assert_equal expected, tiptap_for("prosemirror_table").to_html
  end

  def test_to_html_returns_nil_for_a_missing_root
    assert_nil Y::Tiptap.new(Y::Doc.new).to_html("nope")
  end

  def test_to_html_reads_live_state
    doc = Y::Doc.new
    prosemirror = Y::Tiptap.new(doc)

    assert_nil prosemirror.to_html("default"), "no root yet"
    doc.apply_update(File.binread(File.join(FIXTURES, "prosemirror_tiptap.bin")))

    assert_includes prosemirror.to_html, "<h1>Heading One</h1>",
                    "the view tracks the doc; no re-wrap needed after updates"
  end

  def test_to_html_covers_the_node_and_mark_set
    html = tiptap_for("prosemirror_tiptap").to_html

    {
      "headings" => "<h6>Heading Six</h6>",
      "bold+italic combo" => "<strong><em>bolditalic</em></strong>",
      "full mark stack" => "<strong><em><s><u><mark><sub>deep</sub></mark></u></s></em></strong>",
      "highlight" => "<mark>hl</mark>",
      "escaping" => "escapes: &lt;tag&gt; &amp; \"quote\" done",
      "link attr order" =>
        '<a target="_blank" rel="noopener noreferrer nofollow" href="https://ex.com/a?b=1&amp;c=2">link</a>',
      "blockquote" => "<blockquote><p>A quote paragraph.</p></blockquote>",
      "nested list" => "<li><p>second</p><ul><li><p>nested a</p></li>",
      "ordered start" => '<ol start="5"><li><p>five</p></li></ol>',
      "task list" =>
        '<li data-checked="true" data-type="taskItem"><label><input type="checkbox" checked="checked">',
      "code block language" => '<pre><code class="language-ruby">def hi',
      "code block plain" => "<pre><code>plain code &lt;x&gt;</code></pre>",
      "hard break" => "<p>line1<br>line2</p>",
      "horizontal rule" => "<hr>",
      "image" => '<img src="https://ex.com/photo.png" alt="a &amp; b" title="the title">'
    }.each do |what, snippet|
      assert_includes html, snippet, "#{what} did not render canonically"
    end
  end

  def test_to_html_renders_mentions
    expected = File.read(File.join(FIXTURES, "prosemirror_mention.html"))
    html = tiptap_for("prosemirror_mention").to_html

    assert_equal expected, html
    assert_includes html, '<span data-type="mention" data-id="u42" data-label="Alice"'
    assert_includes html, ">@Alice</span>"
    assert_includes html, ">@u7</span>", "a label-less mention falls back to its id"
  end

  # The details family follows tiptap-php's renderHTML (the Tiptap extension
  # is Pro-only, so tiptap-php is the reference).
  def test_to_html_renders_the_details_family
    expected = File.read(File.join(FIXTURES, "prosemirror_details.html"))
    html = tiptap_for("prosemirror_details").to_html

    assert_equal expected, html
    assert_includes html, '<details open="open"><summary>More info</summary>'
    assert_includes html, "<details><summary></summary></details>", "a closed details omits open"
  end

  def test_to_html_renders_text_styles
    expected = File.read(File.join(FIXTURES, "prosemirror_textstyle.html"))
    html = tiptap_for("prosemirror_textstyle").to_html

    assert_equal expected, html
    assert_includes html, '<span style="color: rgb(255, 0, 0);">red</span>'
    assert_includes html,
                    '<span style="color: rgb(0, 128, 0); font-family: monospace;"><strong>both-bold</strong></span>'
  end

  def test_to_html_rejects_extra_arguments
    error = assert_raises(ArgumentError) do
      Y::Tiptap.new(Y::Doc.new).to_html("default", "extra")
    end
    assert_match(/given 2, expected 0\.\.1/, error.message)
  end
end
