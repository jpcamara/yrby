# frozen_string_literal: true

# How StreamingWriter makes the blocks it types into: a paragraph, a heading,
# a list item, each at the insertion point if there is one, otherwise at the
# end. A paragraph or heading starts with its text node's marker; without it
# an editor has no text node to show the characters in.
module StreamingBlocks
  private

  def new_paragraph
    @paragraph_text = +""
    para = nil
    change do
      para = new_block(Y::Lexical::PARAGRAPH_ATTRIBUTES)
      para.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
    end
    para
  end

  # A new top-level block: at the insertion point if there is one (advancing
  # it), otherwise at the end.
  def new_block(attributes)
    root = @doc.get_xml_text("root")
    return root.push_xml_text(attributes) unless @at

    block = root.insert_xml_text(@at, attributes)
    @at += 1
    block
  end

  # A heading: the line's leading hashes give its level.
  def new_heading
    level = [@line[/\A#+/].length, 6].min
    block = nil
    change do
      block = new_block(Y::Lexical.heading_attributes("h#{level}"))
      block.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
    end
    @paragraph = nil
    @prose_lines = 0
    block
  end

  def new_item(ordered: false)
    @list = nil if @list && @list_ordered != ordered # a numbered list after a bulleted one is a new list
    @list_ordered = ordered
    item = nil
    change do
      @list ||= new_block(Y::Lexxy.list_attributes(ordered: ordered))
      value = @list.xml_text_count + 1
      item = @list.push_xml_text(Y::Lexxy.list_item_attributes(value))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
    end
    item
  end
end
