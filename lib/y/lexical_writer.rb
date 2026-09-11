# frozen_string_literal: true

module Y
  # Writing to a Lexical document from Ruby.
  #
  # Lexical keeps its document in a root `XmlText`. Each block is an `XmlText`
  # embedded in it, carrying the node's properties as attributes. Inside a
  # block, a text node is an embedded marker (its properties) followed by the
  # characters. These helpers build exactly that shape, so what Ruby appends
  # renders the same as what a person typed, and an open editor applies it as
  # an ordinary remote edit.
  class Lexical
    PARAGRAPH_ATTRIBUTES = {
      "__type" => "paragraph", "__format" => 0, "__style" => "", "__indent" => 0,
      "__dir" => nil, "__textFormat" => 0, "__textStyle" => ""
    }.freeze

    TEXT_ATTRIBUTES = {
      "__type" => "text", "__format" => 0, "__style" => "", "__mode" => 0, "__detail" => 0
    }.freeze

    # A heading block: `tag` is "h1".."h6".
    def self.heading_attributes(tag)
      { "__type" => "heading", "__tag" => tag.to_s, "__format" => 0, "__style" => "",
        "__indent" => 0, "__dir" => nil, "__textFormat" => 0, "__textStyle" => "" }
    end

    # Append a paragraph of plain text to the document and return the live
    # block. The root is "root", Lexical's default.
    def self.append_paragraph(doc, text, root: "root")
      append_block(doc, PARAGRAPH_ATTRIBUTES, text, root: root)
    end

    # Append a heading (`tag:` "h1".."h6") and return the live block.
    def self.append_heading(doc, text, tag: "h2", root: "root")
      append_block(doc, heading_attributes(tag), text, root: root)
    end

    # A list block: `ordered:` false is a bulleted list ("ul"), true a numbered
    # one ("ol").
    def self.list_attributes(ordered: false)
      { "__type" => "list", "__tag" => ordered ? "ol" : "ul",
        "__listType" => ordered ? "number" : "bullet", "__start" => 1,
        "__format" => 0, "__style" => "", "__indent" => 0, "__dir" => nil,
        "__textFormat" => 0, "__textStyle" => "" }
    end

    # A list item; `value` is its 1-based position. The item node's type is
    # `list_item_type`, which an editor flavor can override (Lexxy uses its own).
    def self.list_item_attributes(value)
      { "__type" => list_item_type, "__value" => value, "__format" => 0, "__style" => "",
        "__indent" => 0, "__dir" => nil, "__textFormat" => 0, "__textStyle" => "" }
    end

    def self.list_item_type
      "listitem"
    end

    # Append a list of plain-text `items` and return the live list block.
    def self.append_list(doc, items, ordered: false, root: "root")
      list = doc.get_xml_text(root).push_xml_text(list_attributes(ordered: ordered))
      items.each_with_index do |text, i|
        item = list.push_xml_text(list_item_attributes(i + 1))
        item.insert_embed(0, TEXT_ATTRIBUTES)
        item.insert(1, text.to_s)
      end
      list
    end

    # Append a block with `attributes` holding one text node of `text`.
    def self.append_block(doc, attributes, text, root: "root")
      block = doc.get_xml_text(root).push_xml_text(attributes)
      block.insert_embed(0, TEXT_ATTRIBUTES)
      block.insert(1, text.to_s)
      block
    end
  end
end
