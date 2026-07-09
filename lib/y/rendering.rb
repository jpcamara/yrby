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
  # Two kinds of rule:
  #
  # - Declarative (a Hash): markup as data, rendered natively at full speed.
  #     Y::ProseMirror.new(doc, nodes: {
  #       "callout" => { tag: "aside",
  #                      attrs: { "class" => ["callout callout--", :kind] },
  #                      content: :blocks }
  #     })
  #   `tag` is the element; `attrs` values are templates — a String literal,
  #   a Symbol referencing one of the node's stored attributes, or an Array
  #   mixing both (an attribute that resolves empty is omitted); `text` is a
  #   template for literal text content; `void: true` emits no closing tag;
  #   `content` is what renders inside: :inline (default), :blocks, or :none.
  #
  # - Callback (a callable, or `render:` in a Hash to also set `content`):
  #     Y::Lexical.new(doc, nodes: {
  #       "video_embed" => ->(node) { %(<video src="#{ERB::Util.html_escape(node.attrs["src"])}"></video>) }
  #     })
  #   The block runs after the document read has finished (never while the
  #   document is locked) and receives a RenderRules::Node with the node's
  #   type, stored attributes, and children already rendered to HTML. Its
  #   return value is spliced in verbatim — it is trusted HTML, so escape any
  #   attribute values you interpolate.
  #
  # Mark rules (ProseMirror only) are declarative: `tag` plus `attrs`
  # templates whose Symbol refs resolve against the mark's own attributes. A
  # custom mark wraps outside every built-in mark; several custom marks nest
  # alphabetically.
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
        compiled["content"] = rule[:content].to_s if rule[:content]
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
      compiled["content"] = rule[:content].to_s if rule[:content]
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

  class Lexical
    # `Y::Lexical.new(doc, nodes: { "type" => rule })` — see Y::RenderRules
    # for the rule forms. The Lexxy-specific schema (Y::Lexxy::NODES) is
    # applied beneath the app's rules: the native renderer covers core
    # Lexical, and an app rule for a Lexxy type replaces it.
    def self.new(doc, nodes: {})
      nodes = Lexxy::NODES.merge(nodes.transform_keys(&:to_s))
      rules_json, callbacks = RenderRules.compile(nodes, {})
      renderer = _native_new(doc, rules_json)
      renderer.instance_variable_set(:@render_callbacks, callbacks)
      renderer
    end

    def to_html(root = nil)
      result = root.nil? ? _native_to_html : _native_to_html(root)
      return result unless result.is_a?(Array)

      RenderRules.splice(result, @render_callbacks)
    end
  end

  class ProseMirror
    # `Y::ProseMirror.new(doc, nodes: {...}, marks: {...})` — see
    # Y::RenderRules for the rule forms.
    def self.new(doc, nodes: {}, marks: {})
      rules_json, callbacks = RenderRules.compile(nodes, marks)
      renderer = _native_new(doc, rules_json)
      renderer.instance_variable_set(:@render_callbacks, callbacks)
      renderer
    end

    def to_html(root = nil)
      result = root.nil? ? _native_to_html : _native_to_html(root)
      return result unless result.is_a?(Array)

      RenderRules.splice(result, @render_callbacks)
    end
  end
end
