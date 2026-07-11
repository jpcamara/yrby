# frozen_string_literal: true

module Y
  # The Lexxy-specific half of the Lexical schema, expressed as render rules —
  # the same extension API apps use, so this file doubles as the reference for
  # augmenting a renderer: simple nodes are declarative hashes, nodes with
  # logic are plain methods mapped in NODES.
  #
  # The native renderer handles core Lexical structure (paragraphs, headings,
  # quotes, code, lists, tables, text formatting, links). Everything Lexxy
  # adds or restyles lives here. `Y::Lexical.new` applies NODES beneath the
  # app's rules, so an app rule for one of these types simply replaces it.
  #
  # The Lexxy-parity guarantee is unchanged: the fixture tests hold
  # `Y::Lexical.new(doc).to_html` byte-identical to a live editor's own
  # serialized value.
  module Lexxy
    module_function

    # A cursor-placement placeholder; empty ones export to nothing.
    def provisional_paragraph(node)
      node.content.empty? ? "" : "<p>#{node.content}</p>"
    end

    # Adjacent previewable images; the class carries the image count
    # (ActionText's convention).
    def gallery(node)
      %(<div class="attachment-gallery attachment-gallery--#{node.child_types.length}">#{node.content}</div>)
    end

    # Lexxy wraps tables in a styled figure.
    def table(node)
      %(<figure class="lexxy-content__table-wrapper"><table><tbody>#{node.content}</tbody></table></figure>)
    end

    # Class + background match Lexxy's own header-cell export.
    def table_cell(node)
      header = node.attrs["__headerState"].is_a?(Numeric) && node.attrs["__headerState"].positive?
      return "<td>#{node.content}</td>" unless header

      style = %(style="background-color: rgb(242, 243, 245);")
      %(<th class="lexxy-content__table-cell--header" #{style}>#{node.content}</th>)
    end

    # Attribute order follows Lexxy's export — checked items put aria-checked
    # before value; items holding a nested list append the
    # lexxy-nested-listitem class after value.
    def list_item(node)
      out = +"<li"
      checked = node.attrs["__checked"]
      out << %( aria-checked="#{checked}") unless checked.nil?
      out << %( value="#{node.attrs["__value"] || 1}")
      out << %( class="lexxy-nested-listitem") if node.child_types.include?("list")
      "#{out}>#{node.content}</li>"
    end

    # An upload, in the exact shape ActionText round-trips: attribute order
    # and presence mirror Lexxy's exportDOM (nulls omitted, `previewable`
    # only when true, `presentation="gallery"` always).
    def upload(node)
      out = +"<action-text-attachment"
      out << attachment_attr(node, "sgid", "sgid")
      out << %( previewable="true") if node.attrs["previewable"] == true
      [%w[url src], %w[alt altText], %w[caption caption],
       %w[content-type contentType], %w[filename fileName],
       %w[filesize fileSize], %w[width width], %w[height height]]
        .each { |html_name, stored| out << attachment_attr(node, html_name, stored) }
      %(#{out} presentation="gallery"></action-text-attachment>)
    end

    # A content attachment (mention, embed): `content` carries the escaped
    # inner HTML; `plainText` is not exported.
    def mention(node)
      out = +"<action-text-attachment"
      out << attachment_attr(node, "sgid", "sgid")
      out << attachment_attr(node, "content", "innerHtml")
      out << attachment_attr(node, "content-type", "contentType")
      "#{out}></action-text-attachment>"
    end

    # A stored nil (unset) is skipped; a stored empty string still emits.
    def attachment_attr(node, html_name, stored)
      return "" if node.attrs[stored].nil?

      %( #{html_name}="#{RenderRules.escape_attr(node.attrs[stored])}")
    end

    NODES = {
      # Lexxy's replacement for Lexical's CodeNode.
      "early_escape_code" => { tag: "pre", attrs: { "data-language" => :language } },
      "horizontal_divider" => { tag: "hr", void: true },
      "provisonal_paragraph" => method(:provisional_paragraph), # (sic: Lexxy's spelling)
      "image_gallery" => method(:gallery),
      "table" => { content: :blocks, render: method(:table) },
      "wrapped_table_node" => { content: :blocks, render: method(:table) },
      "tablecell" => { content: :blocks, render: method(:table_cell) },
      "listitem" => { content: :blocks, render: method(:list_item) },
      "action_text_attachment" => method(:upload),
      "custom_action_text_attachment" => method(:mention)
    }.freeze
  end
end
