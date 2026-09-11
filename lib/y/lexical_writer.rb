# frozen_string_literal: true

module Y
  # Writing to a Lexical document from Ruby.
  #
  # Lexical keeps its document in a root `XmlText`. Each block is an `XmlText`
  # embedded in it, carrying the node's properties as attributes. Inside a
  # block, a text node is an embedded marker (a map of its properties)
  # followed by the characters; a run of formatted text is its own marker and
  # characters. These helpers build exactly that shape, so what Ruby writes
  # renders the same as what a person typed, and an open editor applies it as
  # an ordinary remote edit.
  class Lexical
    ELEMENT_ATTRIBUTES = {
      "__format" => 0, "__style" => "", "__indent" => 0, "__dir" => nil,
      "__textFormat" => 0, "__textStyle" => ""
    }.freeze

    PARAGRAPH_ATTRIBUTES = { "__type" => "paragraph", **ELEMENT_ATTRIBUTES }.freeze

    TEXT_ATTRIBUTES = {
      "__type" => "text", "__format" => 0, "__style" => "", "__mode" => 0, "__detail" => 0
    }.freeze

    # Lexical's text format bits.
    FORMAT = { bold: 1, italic: 2, strikethrough: 4, underline: 8, code: 16 }.freeze

    # A heading block: `tag` is "h1".."h6".
    def self.heading_attributes(tag)
      { "__type" => "heading", "__tag" => tag.to_s, **ELEMENT_ATTRIBUTES }
    end

    def self.quote_attributes
      { "__type" => "quote", **ELEMENT_ATTRIBUTES }
    end

    # A code block. Its text nodes are `code-highlight` nodes.
    def self.code_attributes(language: "plain")
      { "__type" => "code", "__language" => language.to_s, **ELEMENT_ATTRIBUTES }
    end

    CODE_TEXT_ATTRIBUTES = { **TEXT_ATTRIBUTES, "__type" => "code-highlight" }.freeze

    # A text node's marker with a format from FORMAT keys, e.g. bold: true.
    def self.text_attributes(**format)
      bits = format.sum { |name, on| on ? FORMAT.fetch(name) : 0 }
      { **TEXT_ATTRIBUTES, "__format" => bits }
    end

    # A list block: `ordered:` false is a bulleted list ("ul"), true a numbered
    # one ("ol").
    def self.list_attributes(ordered: false)
      { "__type" => "list", "__tag" => ordered ? "ol" : "ul",
        "__listType" => ordered ? "number" : "bullet", "__start" => 1, **ELEMENT_ATTRIBUTES }
    end

    # A list item; `value` is its 1-based position. The item node's type is
    # `list_item_type`, which an editor flavor can override (Lexxy uses its own).
    def self.list_item_attributes(value)
      { "__type" => list_item_type, "__value" => value, **ELEMENT_ATTRIBUTES }
    end

    def self.list_item_type
      "listitem"
    end

    # A link inside a block: an element holding its own text nodes.
    def self.link_attributes(url, title: nil)
      { "__type" => "link", "__url" => url.to_s, "__target" => nil, "__rel" => nil,
        "__title" => title, **ELEMENT_ATTRIBUTES }
    end

    # --- appending blocks ---

    # Append a paragraph and return the live block. `runs` is a string, or an
    # array of strings and hashes like `{ text: "bold", bold: true }` or
    # `{ text: "docs", link: "https://…" }`.
    def self.append_paragraph(doc, runs, root: "root")
      append_block(doc, PARAGRAPH_ATTRIBUTES, runs, root: root)
    end

    # Append a heading (`tag:` "h1".."h6") and return the live block.
    def self.append_heading(doc, runs, tag: "h2", root: "root")
      append_block(doc, heading_attributes(tag), runs, root: root)
    end

    def self.append_quote(doc, runs, root: "root")
      append_block(doc, quote_attributes, runs, root: root)
    end

    # Append a code block. Lines stay as they are; `language:` names the syntax.
    def self.append_code(doc, code, language: "plain", root: "root")
      block = doc.get_xml_text(root).push_xml_text(code_attributes(language: language))
      block.insert_embed(0, CODE_TEXT_ATTRIBUTES)
      block.insert(1, code.to_s)
      block
    end

    # Append a list of `items` (each a string or runs) and return the live list.
    def self.append_list(doc, items, ordered: false, root: "root")
      list = doc.get_xml_text(root).push_xml_text(list_attributes(ordered: ordered))
      items.each_with_index do |runs, i|
        item = list.push_xml_text(list_item_attributes(i + 1))
        write_runs(item, runs)
      end
      list
    end

    # Append a block with `attributes` holding `runs`.
    def self.append_block(doc, attributes, runs, root: "root")
      block = doc.get_xml_text(root).push_xml_text(attributes)
      write_runs(block, runs)
      block
    end

    # --- editing in place ---

    # Insert a paragraph before the `at`-th block (at the end when past the
    # last) and return it.
    def self.insert_paragraph(doc, at, runs, root: "root")
      block = doc.get_xml_text(root).insert_xml_text(at, PARAGRAPH_ATTRIBUTES)
      write_runs(block, runs)
      block
    end

    # Replace everything in a block with `runs`.
    def self.replace_runs(block, runs)
      block.clear
      write_runs(block, runs)
      block
    end

    # Remove the `at`-th block. Returns whether there was one.
    def self.delete_block(doc, at, root: "root")
      doc.get_xml_text(root).delete_xml_text(at)
    end

    # Write `runs` at the end of `block`: a text node per run, a link element
    # for a run with `link:`.
    def self.write_runs(block, runs)
      Array(runs).each do |run|
        run = { text: run } if run.is_a?(String)
        if run[:link]
          link = block.push_xml_text(link_attributes(run[:link], title: run[:title]))
          write_text(link, run.except(:link, :title))
        else
          write_text(block, run)
        end
      end
      block
    end

    def self.write_text(block, run)
      format = run.slice(*FORMAT.keys)
      block.insert_embed(block.length, text_attributes(**format))
      block.insert(block.length, run[:text].to_s)
    end
    private_class_method :write_text
  end
end
