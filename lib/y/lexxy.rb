# frozen_string_literal: true

module Y
  # The Lexxy-specific half of the Lexical schema, expressed as render rules.
  #
  # The native renderer handles core Lexical structure — paragraphs,
  # headings, quotes, code, lists, tables, text formatting, links. Everything
  # Lexxy adds or restyles lives here, built on the same extension API apps
  # use: its own node types (attachments, galleries, its code and divider
  # nodes) and its decorations of core nodes (the table figure wrapper,
  # header-cell styling, the nested-list-item class). `Y::Lexical.new`
  # applies these by default, beneath any rules the app passes — so an app
  # rule for one of these types simply replaces it.
  #
  # The Lexxy-parity guarantee is unchanged: the fixture tests hold
  # `Y::Lexical.new(doc).to_html` byte-identical to a live editor's own
  # serialized value.
  module Lexxy
    upload_attr = lambda { |node, html_name, stored|
      # A stored nil (unset) is skipped; a stored empty string still emits.
      return "" if node.attrs[stored].nil?

      %( #{html_name}="#{RenderRules.escape_attr(node.attrs[stored])}")
    }

    # An upload, in the exact shape ActionText round-trips: attribute order
    # and presence mirror Lexxy's exportDOM (nulls omitted, `previewable`
    # only when true, `presentation="gallery"` always).
    upload = lambda { |node|
      out = "<action-text-attachment#{upload_attr.call(node, "sgid", "sgid")}"
      out += %( previewable="true") if node.attrs["previewable"] == true
      [%w[url src], %w[alt altText], %w[caption caption],
       %w[content-type contentType], %w[filename fileName],
       %w[filesize fileSize], %w[width width], %w[height height]]
        .each { |html_name, stored| out += upload_attr.call(node, html_name, stored) }
      %(#{out} presentation="gallery"></action-text-attachment>)
    }

    # A content attachment (mention, embed): `content` carries the escaped
    # inner HTML; `plainText` is not exported.
    mention = lambda { |node|
      out = "<action-text-attachment#{upload_attr.call(node, "sgid", "sgid")}"
      out += upload_attr.call(node, "content", "innerHtml")
      out += upload_attr.call(node, "content-type", "contentType")
      "#{out}></action-text-attachment>"
    }

    table = lambda { |node|
      %(<figure class="lexxy-content__table-wrapper"><table><tbody>#{node.content}</tbody></table></figure>)
    }

    NODES = {
      # A cursor-placement placeholder; empty ones export to nothing.
      "provisonal_paragraph" => ->(node) { node.content.empty? ? "" : "<p>#{node.content}</p>" },
      # Lexxy's replacement for Lexical's CodeNode.
      "early_escape_code" => { tag: "pre", attrs: { "data-language" => :language } },
      "horizontal_divider" => { tag: "hr", void: true },
      # Adjacent previewable images; the class carries the image count
      # (ActionText's convention).
      "image_gallery" => lambda { |node|
        %(<div class="attachment-gallery attachment-gallery--#{node.child_types.length}">#{node.content}</div>)
      },
      # Lexxy wraps tables in a styled figure.
      "table" => { content: :blocks, render: table },
      "wrapped_table_node" => { content: :blocks, render: table },
      # Class + background match Lexxy's own header-cell export.
      "tablecell" => { content: :blocks, render: lambda { |node|
        header = node.attrs["__headerState"].is_a?(Numeric) && node.attrs["__headerState"].positive?
        if header
          style = %(style="background-color: rgb(242, 243, 245);")
          %(<th class="lexxy-content__table-cell--header" #{style}>#{node.content}</th>)
        else
          "<td>#{node.content}</td>"
        end
      } },
      # Attribute order follows Lexxy's export — checked items put
      # aria-checked before value; items holding a nested list append the
      # lexxy-nested-listitem class after value.
      "listitem" => { content: :blocks, render: lambda { |node|
        out = "<li"
        checked = node.attrs["__checked"]
        out += %( aria-checked="#{checked}") unless checked.nil?
        out += %( value="#{node.attrs["__value"] || 1}")
        out += %( class="lexxy-nested-listitem") if node.child_types.include?("list")
        "#{out}>#{node.content}</li>"
      } },
      "action_text_attachment" => upload,
      "custom_action_text_attachment" => mention
    }.freeze
  end
end
