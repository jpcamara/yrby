# frozen_string_literal: true

require "test_helper"

# Custom render rules (Y::RenderRules): the nodes:/marks: config both
# renderers accept. Declarative rules render natively; callback rules run
# Ruby after the document read has finished and splice into the output. The
# rule engine itself (precedence, templates, segment shapes) is exercised in
# the Rust tests; these cover the Ruby-facing surface end to end.
class RenderingRulesTest < Minitest::Test
  LEXICAL_FIXTURES = File.expand_path("../ext/yrby/crates/lexical-html/src/fixtures", __dir__)
  PROSEMIRROR_FIXTURES = File.expand_path("../ext/yrby/crates/prosemirror-html/src/fixtures", __dir__)

  def lexical_doc(name = "lexxy_full")
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(LEXICAL_FIXTURES, "#{name}.bin")))
    doc
  end

  def prosemirror_doc(name = "prosemirror_tiptap")
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(PROSEMIRROR_FIXTURES, "#{name}.bin")))
    doc
  end

  def test_no_rules_still_returns_a_plain_string
    html = Y::Lexical.new(lexical_doc).to_html

    assert_instance_of String, html
  end

  def test_a_declarative_rule_overrides_a_builtin_node
    html = Y::ProseMirror.new(
      prosemirror_doc,
      nodes: { "blockquote" => { tag: "aside", attrs: { "class" => "quote" }, contains: :blocks } }
    ).to_html

    assert_includes html, '<aside class="quote">'
    refute_includes html, "<blockquote>"
  end

  def test_a_rule_overrides_a_builtin_in_inline_position
    # Links live inside text blocks, not at block level — the rule must
    # reach inline position. The fixture's links store __url.
    html = Y::Lexxy.new(
      lexical_doc,
      nodes: { "link" => { tag: "a", attrs: { "class" => "app-link", "href" => [:url] } } }
    ).to_html

    assert_includes html, '<a class="app-link" href="https://example.com/a?b=1&amp;c=2">'
    refute_includes html, '<a href="https://example.com/a?b=1&amp;c=2">'
  end

  def test_declarative_attr_templates_resolve_stored_attributes
    # The mention fixture stores Tiptap Mention nodes with an `id` attribute.
    html = Y::ProseMirror.new(
      prosemirror_doc("prosemirror_mention"),
      nodes: { "mention" => { tag: "x-mention", attrs: { "data-user" => [:id] }, text: [:label] } }
    ).to_html

    assert_includes html, '<x-mention data-user="'
    refute_includes html, 'data-type="mention"'
  end

  def test_a_callback_rule_receives_the_node_and_splices_its_return_value
    seen = []
    html = Y::Lexical.new(
      lexical_doc,
      nodes: {
        "paragraph" => lambda { |node|
          seen << node
          %(<p data-cb="1">#{node.content}</p>)
        }
      }
    ).to_html

    assert_includes html, '<p data-cb="1">'
    refute_empty seen
    assert_equal "paragraph", seen.first.type
    assert_instance_of Hash, seen.first.attrs
    assert_instance_of Array, seen.first.child_types
    assert(seen.any? { |node| node.content.include?("<strong>") },
           "children arrive as already-rendered HTML")
  end

  def test_a_callback_may_touch_the_same_doc
    # Callbacks run after the render's transaction has closed. Reading and
    # writing the doc from inside one must not deadlock against the render.
    doc = lexical_doc
    renderer = Y::Lexical.new(doc)
    html = Y::ProseMirror.new(
      prosemirror_doc,
      nodes: {
        "horizontalRule" => lambda { |_node|
          doc.apply_update(File.binread(File.join(LEXICAL_FIXTURES, "lexxy_full.bin")))
          renderer.to_html # a fresh read transaction on another doc view
          %(<hr data-cb="1">)
        }
      }
    ).to_html

    assert_includes html, %(<hr data-cb="1">)
  end

  def test_a_custom_mark_wraps_outside_the_builtins
    html = Y::ProseMirror.new(
      prosemirror_doc,
      marks: { "bold" => { tag: "b" } }
    ).to_html

    assert_includes html, "<b>"
    refute_includes html, "<strong>"
  end

  def test_invalid_rule_config_raises_argument_error
    doc = Y::Doc.new

    error = assert_raises(ArgumentError) do
      Y::ProseMirror.new(doc, nodes: { "callout" => { contains: :blocks } }) # no tag, no callback
    end
    assert_match(/needs a tag/, error.message)

    assert_raises(ArgumentError) do
      Y::ProseMirror.new(doc, nodes: { "callout" => { tag: "aside", contains: :wat } })
    end
    assert_raises(ArgumentError) do
      Y::Lexical.new(doc, nodes: { "callout" => "not a rule" })
    end
    assert_raises(ArgumentError, "marks are ProseMirror-only") do
      Y::Lexical.new(doc, marks: { "comment" => { tag: "span" } })
    end
  end

  # The Lexxy-specific half of the schema ships as Y::Lexxy's rule set on
  # top of the core Y::Lexical renderer — the byte-parity fixture tests in
  # html_test.rb exercise the extension path on every render. These cover the
  # layering itself.
  def test_the_lexxy_layer_is_rules_and_user_rules_override_it
    assert_instance_of Hash, Y::Lexxy::NODES
    assert_predicate Y::Lexxy::NODES, :frozen?

    # The gallery fixture holds three uploads; a user rule for the type
    # replaces the shipped Lexxy rendering.
    html = Y::Lexxy.new(
      lexical_doc("lexxy_gallery"),
      nodes: {
        "action_text_attachment" => lambda { |node|
          %(<img src="#{Y::RenderRules.escape_attr(node.attrs["src"])}" loading="lazy">)
        }
      }
    ).to_html

    assert_includes html, %(<img src=)
    assert_includes html, %(loading="lazy")
    refute_includes html, "<action-text-attachment"
    assert_includes html, "attachment-gallery--3", "untouched Lexxy rules still apply"
  end

  def test_the_block_form_registers_declarative_callback_and_mark_rules
    html = Y::ProseMirror.new(prosemirror_doc) do |rules|
      rules.node "blockquote", tag: "aside", attrs: { "class" => "quote" }, contains: :blocks
      rules.node "horizontalRule" do |node|
        %(<hr data-cb="#{node.type}">)
      end
      rules.node "bulletList", contains: :blocks do |node|
        %(<ul data-count="#{node.child_types.length}">#{node.content}</ul>)
      end
      rules.mark "bold", tag: "b"
    end.to_html

    assert_includes html, '<aside class="quote">'
    assert_includes html, '<hr data-cb="horizontalRule">'
    assert_match(/<ul data-count="\d+">/, html)
    assert_includes html, "<b>"
    refute_includes html, "<strong>"

    assert_raises(ArgumentError, "marks are ProseMirror-only") do
      Y::Lexical.new(Y::Doc.new) { |rules| rules.mark "comment", tag: "span" }
    end
  end

  # The discovery aid: ask a real document which node types it holds, what
  # they look like (attrs as stored, child types, text), and which ones
  # still need a rule ("handled" nil).
  def test_node_types_reports_the_documents_schema_as_facts
    types = Y::Lexxy.new(lexical_doc).node_types

    assert_equal "builtin", types["paragraph"]["handled"]
    assert_equal "rule", types["action_text_attachment"]["handled"],
                 "Y::Lexxy's schema covers attachments"
    assert_includes types["heading"]["attrs"], "__tag"
    assert types["paragraph"]["text"]

    # Core Y::Lexical reports the same type as unhandled — it needs a rule
    # (or Y::Lexxy).
    core = Y::Lexical.new(lexical_doc).node_types

    assert_nil core["action_text_attachment"]["handled"]

    # Same split on the ProseMirror side: core reports mention unhandled,
    # Y::Tiptap's schema covers it.
    pm_core = Y::ProseMirror.new(prosemirror_doc("prosemirror_mention")).node_types

    assert_nil pm_core["mention"]["handled"]
    assert_includes pm_core["mention"]["attrs"], "mentionSuggestionChar"
    assert_includes pm_core["paragraph"]["children"], "mention"

    pm_types = Y::Tiptap.new(prosemirror_doc("prosemirror_mention")).node_types

    assert_equal "rule", pm_types["mention"]["handled"]

    assert_nil Y::Lexical.new(Y::Doc.new).node_types("nope")
  end

  def test_rules_hold_up_under_concurrent_renders
    renderer = Y::Lexical.new(
      lexical_doc,
      nodes: { "paragraph" => ->(node) { "<p>#{node.content}</p>" } }
    )
    reference = renderer.to_html

    results = Array.new(8) do
      Thread.new { Array.new(25) { renderer.to_html } }
    end.flat_map(&:value)

    assert(results.all? { |html| html == reference })
  end
end
