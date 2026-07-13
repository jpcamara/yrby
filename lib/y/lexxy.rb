# frozen_string_literal: true

module Y
  # The Lexxy renderer: Y::Lexical (core Lexical) plus the Lexxy-specific
  # schema, applied beneath the app's rules — an app rule for one of these
  # types simply replaces it. This is the byte-parity class: the fixture
  # tests hold `Y::Lexxy.new(doc).to_html` identical to a live editor's own
  # serialized value.
  #
  # The schema doubles as the reference for augmenting a renderer: simple
  # nodes are declarative hashes, nodes with logic are plain methods mapped
  # in NODES.
  class Lexxy < Lexical
    # A cursor-placement placeholder; empty ones export to nothing.
    def self.provisional_paragraph(node)
      node.content.empty? ? "" : "<p>#{node.content}</p>"
    end

    # Adjacent previewable images; the class carries the image count
    # (ActionText's convention).
    def self.gallery(node)
      %(<div class="attachment-gallery attachment-gallery--#{node.child_types.length}">#{node.content}</div>)
    end

    # Lexxy wraps tables in a styled figure.
    def self.table(node)
      %(<figure class="lexxy-content__table-wrapper"><table><tbody>#{node.content}</tbody></table></figure>)
    end

    # Class + background match Lexxy's own header-cell export.
    def self.table_cell(node)
      header = node.attrs["__headerState"].is_a?(Numeric) && node.attrs["__headerState"].positive?
      return "<td>#{node.content}</td>" unless header

      style = %(style="background-color: rgb(242, 243, 245);")
      %(<th class="lexxy-content__table-cell--header" #{style}>#{node.content}</th>)
    end

    # Attribute order follows Lexxy's export — checked items put aria-checked
    # before value; items holding a nested list append the
    # lexxy-nested-listitem class after value.
    def self.list_item(node)
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
    def self.upload(node)
      tag = attachment_tag(node)
      out = "<#{tag}"
      out << attachment_attr(node, "sgid", "sgid")
      out << %( previewable="true") if node.attrs["previewable"] == true
      [%w[url src], %w[alt altText], %w[caption caption],
       %w[content-type contentType], %w[filename fileName],
       %w[filesize fileSize], %w[width width], %w[height height]]
        .each { |html_name, stored| out << attachment_attr(node, html_name, stored) }
      %(#{out} presentation="gallery"></#{tag}>)
    end

    # A content attachment (mention, embed): `content` carries the escaped
    # inner HTML; `plainText` is not exported.
    def self.mention(node)
      tag = attachment_tag(node)
      out = "<#{tag}"
      out << attachment_attr(node, "sgid", "sgid")
      out << attachment_attr(node, "content", "innerHtml")
      out << attachment_attr(node, "content-type", "contentType")
      "#{out}></#{tag}>"
    end

    # Lexxy's attachment tag is configurable (`Lexxy.configure`'s
    # attachmentTagName, paired with ActionText::Attachment.tag_name on the
    # Rails side), and each attachment node stores the tag it was created
    # with. Emit the stored tag. The value is stored document data, not
    # markup, so anything that doesn't look like a tag name falls back to
    # ActionText's default.
    def self.attachment_tag(node)
      tag = node.attrs["tagName"].to_s
      tag.match?(/\A[a-zA-Z][a-zA-Z0-9-]*\z/) ? tag : "action-text-attachment"
    end

    # A stored nil (unset) is skipped; a stored empty string still emits.
    def self.attachment_attr(node, html_name, stored)
      return "" if node.attrs[stored].nil?

      %( #{html_name}="#{RenderRules.escape_attr(node.attrs[stored])}")
    end

    NODES = {
      # Lexxy's replacement for Lexical's CodeNode.
      "early_escape_code" => { tag: "pre", attrs: { "data-language" => :language } },
      "horizontal_divider" => { tag: "hr", void: true },
      "provisonal_paragraph" => method(:provisional_paragraph), # (sic: Lexxy's spelling)
      "image_gallery" => method(:gallery),
      "table" => { contains: :blocks, render: method(:table) },
      "wrapped_table_node" => { contains: :blocks, render: method(:table) },
      "tablecell" => { contains: :blocks, render: method(:table_cell) },
      "listitem" => { contains: :blocks, render: method(:list_item) },
      "action_text_attachment" => method(:upload),
      "custom_action_text_attachment" => method(:mention)
    }.freeze

    def initialize(doc, nodes: {}, &)
      super(doc, nodes: NODES.merge(nodes.transform_keys(&:to_s)), &)
    end
  end
end
