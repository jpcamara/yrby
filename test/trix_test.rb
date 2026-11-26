# frozen_string_literal: true

require "test_helper"
require "json"

# Y::Trix: a Trix document kept in a Y.Text (the y-trix binding's format),
# rendered to the HTML Trix saves. test/fixtures/trix.json holds documents
# captured from real Trix editors bound with y-trix: `update` is the Yjs
# state and `html` is what the editor's form input held. y-trix writes the
# file (FIXTURES_OUT=... npx playwright test fixtures, in its repository).
# It covers every block and text attribute, nesting, attachments, right to
# left text, shapes written straight into the Y.Text that no Trix command
# makes, and a few hundred generated documents.
class TrixTest < Minitest::Test
  FIXTURES = JSON.parse(File.read(File.expand_path("fixtures/trix.json", __dir__)))
  SHOW = ->(html) { html }

  def doc_for(update)
    Y::Doc.new.tap { |doc| doc.apply_update(update.unpack1("m")) }
  end

  def doc_with
    Y::Doc.new.tap { |doc| yield doc.get_text("trix") }
  end

  def test_to_html_matches_what_trix_saves_for_every_fixture
    assert_operator FIXTURES.size, :>, 250
    FIXTURES.each do |fixture|
      assert_equal fixture["html"], Y::Trix.new(doc_for(fixture["update"]), content: SHOW).to_html, fixture["name"]
    end
  end

  def test_to_html_takes_the_root_name
    fixture = FIXTURES.find { |f| f["name"] == "inline formats" }

    assert_equal fixture["html"], Y::Trix.new(doc_for(fixture["update"])).to_html("trix")
    assert_equal fixture["html"], Y::Trix.new(doc_for(fixture["update"])).to_html(:trix)
  end

  def test_to_html_is_nil_for_a_missing_root_and_empty_for_an_empty_document
    assert_nil Y::Trix.new(Y::Doc.new).to_html
    assert_nil Y::Trix.new(Y::Doc.new).to_html("nope")
    assert_equal "", Y::Trix.new(doc_with { |text| text.insert(0, "") }).to_html
    assert_equal "", Y::Trix.render([{ "insert" => "\n", "attributes" => { "blockBreak" => true } }])
  end

  def test_render_takes_a_parsed_delta
    delta = [
      { "insert" => "Hello ", "attributes" => { "bold" => true } },
      { "insert" => "world" },
      { "insert" => "\n", "attributes" => { "blockBreak" => true, "block" => ["heading1"] } }
    ]

    assert_equal "<h1><strong>Hello </strong>world</h1>", Y::Trix.render(delta)
  end

  # ---- nothing in the document is trusted ------------------------------------

  def test_text_is_escaped
    html = Y::Trix.render([{ "insert" => %(<script>alert("x")</script> & more) }, block_break])

    assert_equal %(<div>&lt;script&gt;alert("x")&lt;/script&gt; &amp; more</div>), html
  end

  def test_a_link_a_browser_would_run_is_not_a_link
    ["javascript:alert(1)", " java\tscript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,<b>",
     "vbscript:x"].each do |href|
      html = Y::Trix.render([{ "insert" => "click", "attributes" => { "href" => href } }, block_break])

      assert_equal "<div>click</div>", html, href
    end
    html = Y::Trix.render([{ "insert" => "ok", "attributes" => { "href" => %(https://example.com/?a="b"&c) } },
                           block_break])

    assert_equal %(<div><a href="https://example.com/?a=&quot;b&quot;&amp;c">ok</a></div>), html
  end

  def test_the_html_of_a_content_attachment_is_left_out_unless_asked_for
    delta = [{ "insert" => { "attachment" => { "content" => "<img src=x onerror=alert(1)>" } } }, block_break]

    refute_includes Y::Trix.render(delta), "<img"
    assert_includes Y::Trix.render(delta), %(<figure data-trix-attachment="{&quot;content&quot;)
    assert_includes Y::Trix.render(delta, content: ->(_html) { "<b>safe</b>" }), "<b>safe</b><figcaption"
  end

  def test_an_attachment_with_a_url_a_browser_would_run_loses_it
    delta = [
      { "insert" => { "attachment" => { "url" => "javascript:alert(1)", "href" => "javascript:alert(2)",
                                        "contentType" => "image/png", "filename" => "a.png" } } },
      block_break
    ]
    html = Y::Trix.render(delta)

    refute_includes html, "javascript"
    refute_includes html, "<a "
  end

  def test_unknown_attributes_and_embeds_are_not_rendered_as_markup
    delta = [
      { "insert" => "a", "attributes" => { "onclick" => "x", "style" => "color:red", "frozen" => true } },
      { "insert" => { "video" => "https://example.com/v" } },
      { "insert" => 7 },
      { "insert" => "\n",
        "attributes" => { "blockBreak" => true, "block" => %w[script quote], "html" => { "onload" => "x" } } }
    ]

    assert_equal "<blockquote>a��</blockquote>", Y::Trix.render(delta)
  end

  def test_a_delta_that_is_not_one_renders_nothing_and_does_not_raise
    [nil, "text", 5, [nil, 5, "x", {}], [{ "insert" => nil }], [{ "attributes" => 5, "insert" => "a" }]].each do |delta|
      assert_kind_of String, Y::Trix.render(delta)
    end
  end

  def test_text_after_the_last_block_break_is_still_rendered
    assert_equal "<div>loose</div>", Y::Trix.render([{ "insert" => "loose" }])
  end

  private

  def block_break = { "insert" => "\n", "attributes" => { "blockBreak" => true } }
end
