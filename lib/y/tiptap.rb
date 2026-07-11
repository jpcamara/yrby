# frozen_string_literal: true

module Y
  # The Tiptap renderer: Y::ProseMirror (core ProseMirror — schema-basic plus
  # tables) plus Tiptap's extension nodes, applied beneath the app's rules —
  # an app rule for one of these types simply replaces it. This is the
  # byte-parity class: the fixture tests hold `Y::Tiptap.new(doc).to_html`
  # identical to a live editor's own `getHTML()`.
  #
  # Tiptap's marks (underline, highlight, sub/superscript, textStyle) render
  # natively in the base class — mark serialization is text-run machinery
  # the rule system can't express.
  class Tiptap < ProseMirror
    # Tiptap's TaskItem markup: the data-checked flag (false when unset), a
    # label wrapping the checkbox, and the item body in a div.
    def self.task_item(node)
      checked = node.attrs["checked"] == true
      out = %(<li data-checked="#{checked}" data-type="taskItem">)
      out << %(<label><input type="checkbox")
      out << %( checked="checked") if checked
      out << "><span></span></label><div>"
      "#{out}#{node.content}</div></li>"
    end

    # Tiptap's Mention extension (no app-configured HTMLAttributes): data
    # attributes when present, the suggestion char, and @label (falling back
    # to @id) as the text.
    def self.mention(node)
      char = node.attrs["mentionSuggestionChar"] || "@"
      out = +%(<span data-type="mention")
      %w[id label].each do |key|
        next if node.attrs[key].nil?

        out << %( data-#{key}="#{RenderRules.escape_attr(node.attrs[key])}")
      end
      out << %( data-mention-suggestion-char="#{RenderRules.escape_attr(char)}">)
      out << RenderRules.escape_text(char)
      out << RenderRules.escape_text(node.attrs["label"] || node.attrs["id"] || "")
      "#{out}</span>"
    end

    # The details family follows tiptap-php's renderHTML (the Tiptap
    # extension is Pro-only, so there's no free getHTML() to capture
    # against).
    def self.details(node)
      open = node.attrs["open"] == true ? %( open="open") : ""
      "<details#{open}>#{node.content}</details>"
    end

    NODES = {
      "taskList" => { tag: "ul", attrs: { "data-type" => "taskList" }, contains: :blocks },
      "taskItem" => { contains: :blocks, render: method(:task_item) },
      "mention" => method(:mention),
      "details" => { contains: :blocks, render: method(:details) },
      "detailsSummary" => { tag: "summary" },
      "detailsContent" => { tag: "div", attrs: { "data-type" => "detailsContent" }, contains: :blocks }
    }.freeze

    def initialize(doc, nodes: {}, marks: {}, &)
      super(doc, nodes: NODES.merge(nodes.transform_keys(&:to_s)), marks: marks, &)
    end
  end
end
