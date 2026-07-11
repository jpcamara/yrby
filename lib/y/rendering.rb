# frozen_string_literal: true

require "json"

module Y
  # Custom render rules for Y::Lexical and Y::ProseMirror.
  #
  # Both renderers accept a `nodes:` hash mapping a node type (Lexical's
  # `__type`, ProseMirror's node name) to a rule; Y::ProseMirror also accepts
  # `marks:`. A rule is consulted before the built-in schema, so it can add a
  # custom node or override a built-in one.
  #
  # The usual way in is the block form — one `rules.node` call per type,
  # keyword options for markup-as-data, a Ruby block for logic (see Builder
  # below). `contains:` says what's inside the node: :inline (formatted
  # text, the default), :blocks (child block nodes), or :none (a leaf). The
  # nodes:/marks: keywords take the same rules as plain hashes, for shipping
  # rule sets as data.
  #
  # Two kinds of rule:
  #
  # - Declarative (keyword options / a Hash): markup as data, rendered
  #   natively at full speed.
  #     Y::ProseMirror.new(doc) do |rules|
  #       rules.node "callout", tag: "aside",
  #                             attrs: { "class" => ["callout callout--", :kind] },
  #                             contains: :blocks
  #     end
  #   `tag` is the element; `attrs` values are templates — a String literal,
  #   a Symbol referencing one of the node's stored attributes, or an Array
  #   mixing both (an attribute that resolves empty is omitted); `text` is a
  #   template for literal text content; `void: true` emits no closing tag;
  #   `contains` declares what lives inside the node and renders there:
  #   :inline (default) for formatted text, :blocks for child block nodes
  #   (a container), :none for a leaf.
  #
  # - Callback (a block; in the hash form, a callable or `render:` plus
  #   `contains`):
  #     Y::Lexical.new(doc) do |rules|
  #       rules.node "video_embed" do |node|
  #         %(<video src="#{ERB::Util.html_escape(node.attrs["src"])}"></video>)
  #       end
  #     end
  #   The block runs after the document read has finished (never while the
  #   document is locked) and receives a RenderRules::Node with the node's
  #   type, stored attributes, children already rendered to HTML, and
  #   child_types (its element/block children by type). Its return value is
  #   spliced in verbatim — it is trusted HTML, so escape any attribute
  #   values you interpolate.
  #
  # Mark rules (ProseMirror only) are declarative: `tag` plus `attrs`
  # templates whose Symbol refs resolve against the mark's own attributes. A
  # custom mark wraps outside every built-in mark; several custom marks nest
  # alphabetically. A rule for a built-in mark's stored name replaces its
  # wrap (the markup changes, the semantics don't — an overridden code mark
  # still excludes the other formatting).
  module RenderRules
    # What a callback receives. `attrs` keys are as stored (Lexical's own
    # props keep their "__" prefix); `content` is the node's children,
    # already rendered to an HTML string; `child_types` lists the node's
    # element/block children by type, in document order — the structural
    # facts attrs and content can't answer (a gallery's image count, whether
    # a list item holds a nested list).
    Node = Data.define(:type, :attrs, :content, :child_types)

    module_function

    # Compile the user-facing config into [rules_json, callbacks]. Structural
    # validation happens in the native parser, which raises ArgumentError.
    def compile(nodes, marks)
      callbacks = {}
      spec = {}
      unless nodes.empty?
        spec["nodes"] = nodes.to_h do |type, rule|
          [type.to_s, compile_node(type.to_s, rule, callbacks)]
        end
      end
      unless marks.empty?
        spec["marks"] = marks.to_h do |name, rule|
          [name.to_s, compile_mark(name.to_s, rule)]
        end
      end
      [JSON.generate(spec), callbacks]
    end

    def compile_node(type, rule, callbacks)
      if rule.respond_to?(:call)
        callbacks[type] = rule
        return { "callback" => true }
      end
      raise ArgumentError, "rule for #{type.inspect} must be a Hash or a callable" unless rule.is_a?(Hash)

      if rule[:render]
        callbacks[type] = rule[:render]
        compiled = { "callback" => true }
        compiled["content"] = rule[:contains].to_s if rule[:contains]
        return compiled
      end
      compile_declarative_node(rule)
    end

    def compile_declarative_node(rule)
      compiled = {}
      compiled["tag"] = rule[:tag].to_s if rule[:tag]
      compiled["void"] = true if rule[:void]
      compiled["attrs"] = compile_attrs(rule[:attrs]) if rule[:attrs]
      compiled["text"] = compile_parts(rule[:text]) if rule[:text]
      compiled["content"] = rule[:contains].to_s if rule[:contains]
      compiled
    end

    def compile_mark(name, rule)
      raise ArgumentError, "mark rule for #{name.inspect} must be a Hash" unless rule.is_a?(Hash)

      compiled = {}
      compiled["tag"] = rule[:tag].to_s if rule[:tag]
      compiled["attrs"] = compile_attrs(rule[:attrs]) if rule[:attrs]
      compiled
    end

    def compile_attrs(attrs)
      attrs.map { |name, template| [name.to_s, compile_parts(template)] }
    end

    # A template: String literal, Symbol attribute reference, or an Array of
    # both.
    def compile_parts(template)
      Array(template).map do |part|
        case part
        when Symbol then { "ref" => part.to_s }
        else { "lit" => part.to_s }
        end
      end
    end

    # The escaping the native renderers use, for blocks that build markup
    # from stored values. Text content escapes `&`, `<`, `>` (quotes stay
    # literal, matching the browser serializer); attribute values also
    # escape `"`. Prefer these over ERB::Util.html_escape when byte parity
    # with editor output matters — html_escape also rewrites apostrophes.
    def escape_text(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def escape_attr(value)
      escape_text(value).gsub('"', "&quot;")
    end

    # Yielded by Y::Lexical.new / Y::ProseMirror.new: register rules one
    # call per node type. Keyword options are the markup-as-data; a block is
    # the logic; both together say what a callback node contains and how to
    # render it:
    #
    #   Y::ProseMirror.new(doc) do |rules|
    #     rules.node "callout", tag: "aside", contains: :blocks
    #     rules.node "video" do |node|
    #       %(<video src="#{RenderRules.escape_attr(node.attrs["src"])}"></video>)
    #     end
    #     rules.node "columns", contains: :blocks do |node|
    #       %(<div class="cols--#{node.child_types.length}">#{node.content}</div>)
    #     end
    #     rules.mark "comment", tag: "span", attrs: { "data-comment-id" => :id }
    #   end
    #
    # It compiles to the same rule hashes the nodes:/marks: keywords take, so
    # both forms mean the same thing; the keywords remain the data form for
    # shipping rule sets (Y::Lexxy::NODES is one).
    class Builder
      attr_reader :nodes, :marks

      def initialize(marks_allowed:)
        @nodes = {}
        @marks = {}
        @marks_allowed = marks_allowed
      end

      def node(type, **options, &block)
        @nodes[type.to_s] =
          if block && options.empty?
            block
          elsif block
            options.merge(render: block)
          else
            options
          end
      end

      def mark(name, **options)
        raise ArgumentError, "marks are ProseMirror-only" unless @marks_allowed

        @marks[name.to_s] = options
      end
    end

    # Resolve callback segments depth-first, so a callback's `node.content`
    # is finished HTML even when callback nodes nest.
    def splice(segments, callbacks)
      segments.map do |segment|
        next segment if segment.is_a?(String)

        type, attrs_json, content, child_types = segment
        node = Node.new(type: type, attrs: JSON.parse(attrs_json),
                        content: splice(content, callbacks),
                        child_types: child_types)
        callbacks.fetch(type).call(node).to_s
      end.join
    end
  end

  # Y::Lexical and Y::ProseMirror are plain Ruby facades over the native
  # renderers (Y::NativeLexical / Y::NativeProseMirror, private constants):
  # they compile the rules config, hold the callbacks, and splice deferred
  # segments after a render. The native handle does everything else.
  class Lexical
    # `Y::Lexical.new(doc, nodes: { "type" => rule })` — see Y::RenderRules
    # for the rule forms. This is core Lexical only: paragraphs, headings,
    # quotes, code, lists, tables, links, text formatting. Editor-specific
    # nodes arrive as rules — Y::Lexxy subclasses this with the Lexxy schema;
    # a different Lexical editor brings its own rule set the same way.
    def initialize(doc, nodes: {})
      builder = RenderRules::Builder.new(marks_allowed: false)
      yield builder if block_given?
      nodes = nodes.transform_keys(&:to_s).merge(builder.nodes)
      rules_json, @render_callbacks = RenderRules.compile(nodes, {})
      @native = NativeLexical.new(doc, rules_json)
    end

    def to_html(root = nil)
      result = root.nil? ? @native.to_html : @native.to_html(root)
      return result unless result.is_a?(Array)

      RenderRules.splice(result, @render_callbacks)
    end

    # What node types this document actually contains — the discovery aid
    # for writing rules. Facts per type: "count", "attrs" (names as stored),
    # "children" (child node types), "text" (whether it holds text runs),
    # and "handled" ("builtin", "rule", or nil — nil marks the types you
    # still need a rule for). Children plus text is how you pick contains:.
    def node_types(root = nil)
      json = root.nil? ? @native.node_types : @native.node_types(root)
      json && JSON.parse(json)
    end
  end

  class ProseMirror
    # `Y::ProseMirror.new(doc, nodes: {...}, marks: {...})` — see
    # Y::RenderRules for the rule forms. This is core ProseMirror only:
    # prosemirror-schema-basic plus the prosemirror-tables family, and the
    # full mark set (marks are native — see `rules.mark` for overrides).
    # Editor-specific nodes arrive as rules — Y::Tiptap subclasses this with
    # Tiptap's extension nodes; a different ProseMirror editor brings its
    # own rule set the same way.
    def initialize(doc, nodes: {}, marks: {})
      builder = RenderRules::Builder.new(marks_allowed: true)
      yield builder if block_given?
      nodes = nodes.transform_keys(&:to_s).merge(builder.nodes)
      marks = marks.transform_keys(&:to_s).merge(builder.marks)
      rules_json, @render_callbacks = RenderRules.compile(nodes, marks)
      @native = NativeProseMirror.new(doc, rules_json)
    end

    def to_html(root = nil)
      result = root.nil? ? @native.to_html : @native.to_html(root)
      return result unless result.is_a?(Array)

      RenderRules.splice(result, @render_callbacks)
    end

    # What node types this document actually contains — the discovery aid
    # for writing rules. Facts per type: "count", "attrs" (names as stored),
    # "children" (child node types), "text" (whether it holds text runs),
    # and "handled" ("builtin", "rule", or nil — nil marks the types you
    # still need a rule for). Children plus text is how you pick contains:.
    def node_types(root = nil)
      json = root.nil? ? @native.node_types : @native.node_types(root)
      json && JSON.parse(json)
    end
  end

  private_constant :NativeLexical, :NativeProseMirror
end
