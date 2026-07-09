# frozen_string_literal: true

require "test_helper"

# Custom render rules (Y::RenderRules): the nodes:/marks: config both
# renderers accept. Declarative rules render natively; callback rules run
# Ruby after the document read has finished and splice into the output. The
# rule engine itself (precedence, templates, segment shapes) is exercised in
# the Rust tests; these cover the Ruby-facing surface end to end.
class RenderingRulesTest < Minitest::Test
  FIXTURES = File.expand_path("../ext/yrby/src/fixtures", __dir__)

  def lexical_doc(name = "lexxy_full")
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "#{name}.bin")))
    doc
  end

  def prosemirror_doc(name = "prosemirror_tiptap")
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(FIXTURES, "#{name}.bin")))
    doc
  end

  def test_no_rules_still_returns_a_plain_string
    html = Y::Lexical.new(lexical_doc).to_html

    assert_instance_of String, html
  end

  def test_a_declarative_rule_overrides_a_builtin_node
    html = Y::ProseMirror.new(
      prosemirror_doc,
      nodes: { "blockquote" => { tag: "aside", attrs: { "class" => "quote" }, content: :blocks } }
    ).to_html

    assert_includes html, '<aside class="quote">'
    refute_includes html, "<blockquote>"
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
          doc.apply_update(File.binread(File.join(FIXTURES, "lexxy_full.bin")))
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
      Y::ProseMirror.new(doc, nodes: { "callout" => { content: :blocks } }) # no tag, no callback
    end
    assert_match(/needs a tag/, error.message)

    assert_raises(ArgumentError) do
      Y::ProseMirror.new(doc, nodes: { "callout" => { tag: "aside", content: :wat } })
    end
    assert_raises(ArgumentError) do
      Y::Lexical.new(doc, nodes: { "callout" => "not a rule" })
    end
    assert_raises(ArgumentError, "marks are ProseMirror-only") do
      Y::Lexical.new(doc, marks: { "comment" => { tag: "span" } })
    end
  end

  # The capability proof: the whole built-in Lexxy schema, reimplemented
  # through the public extensibility API — simple nodes as declarative
  # hashes, everything with logic as a block. Registered rules override the
  # built-ins, so this renders every node through the extension path; the
  # output must match the native renderer byte for byte on every captured
  # fixture. If a Lexxy node can't be expressed this way, this test is where
  # that shows up.
  ESC_TEXT = ->(s) { s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;") }
  ESC_ATTR = ->(s) { ESC_TEXT.call(s).gsub('"', "&quot;") }

  def lexxy_schema_as_rules
    code = lambda { |n|
      lang = n.attrs["__language"]
      attrs = lang.to_s.empty? ? "" : %( data-language="#{ESC_ATTR.call(lang)}")
      "<pre#{attrs}>#{n.content}</pre>"
    }
    table = lambda { |n|
      %(<figure class="lexxy-content__table-wrapper"><table><tbody>#{n.content}</tbody></table></figure>)
    }

    lexxy_attachment_rules.merge(
      "paragraph" => ->(n) { n.content.empty? ? "<p><br></p>" : "<p>#{n.content}</p>" },
      "provisonal_paragraph" => ->(n) { n.content.empty? ? "" : "<p>#{n.content}</p>" },
      "heading" => lambda { |n|
        tag = %w[h1 h2 h3 h4 h5 h6].include?(n.attrs["__tag"]) ? n.attrs["__tag"] : "h1"
        "<#{tag}>#{n.content}</#{tag}>"
      },
      "quote" => { tag: "blockquote" },
      "code" => code,
      "early_escape_code" => code,
      "list" => { content: :blocks,
                  render: lambda { |n|
                    tag = n.attrs["__tag"] == "ol" ? "ol" : "ul"
                    "<#{tag}>#{n.content}</#{tag}>"
                  } },
      "listitem" => { content: :blocks, render: lambda { |n|
        out = "<li"
        checked = n.attrs["__checked"]
        out += %( aria-checked="#{checked}") unless checked.nil?
        out += %( value="#{n.attrs["__value"] || 1}")
        out += %( class="lexxy-nested-listitem") if n.child_types.include?("list")
        "#{out}>#{n.content}</li>"
      } },
      "image_gallery" => lambda { |n|
        %(<div class="attachment-gallery attachment-gallery--#{n.child_types.length}">#{n.content}</div>)
      },
      "table" => { content: :blocks, render: table },
      "wrapped_table_node" => { content: :blocks, render: table },
      "tablerow" => { tag: "tr", content: :blocks },
      "tablecell" => { content: :blocks, render: lambda { |n|
        header = n.attrs["__headerState"].is_a?(Numeric) && n.attrs["__headerState"].positive?
        if header
          style = %(style="background-color: rgb(242, 243, 245);")
          %(<th class="lexxy-content__table-cell--header" #{style}>#{n.content}</th>)
        else
          "<td>#{n.content}</td>"
        end
      } },
      "horizontal_divider" => { tag: "hr", void: true }
    )
  end

  def lexxy_attachment_rules
    # A stored nil (unset) is skipped; a stored empty string still emits.
    attr = lambda { |n, html_name, stored|
      n.attrs[stored].nil? ? "" : %( #{html_name}="#{ESC_ATTR.call(n.attrs[stored])}")
    }
    upload = lambda { |n|
      out = "<action-text-attachment#{attr.call(n, "sgid", "sgid")}"
      out += %( previewable="true") if n.attrs["previewable"] == true
      [%w[url src], %w[alt altText], %w[caption caption], %w[content-type contentType],
       %w[filename fileName], %w[filesize fileSize], %w[width width], %w[height height]]
        .each { |html_name, stored| out += attr.call(n, html_name, stored) }
      %(#{out} presentation="gallery"></action-text-attachment>)
    }
    mention = lambda { |n|
      out = "<action-text-attachment#{attr.call(n, "sgid", "sgid")}"
      out += attr.call(n, "content", "innerHtml")
      out += attr.call(n, "content-type", "contentType")
      "#{out}></action-text-attachment>"
    }
    { "action_text_attachment" => upload, "custom_action_text_attachment" => mention }
  end

  def test_the_lexxy_schema_is_implementable_with_the_extensibility
    %w[lexxy_full lexxy_torture lexxy_gallery lexxy_styles].each do |fixture|
      native = Y::Lexical.new(lexical_doc(fixture)).to_html
      reimplemented = Y::Lexical.new(lexical_doc(fixture), nodes: lexxy_schema_as_rules).to_html

      assert_equal native, reimplemented, "schema-via-rules parity on #{fixture}"
    end
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
