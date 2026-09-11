# frozen_string_literal: true

# Block creation for StreamingWriter. Blocks are remembered by anchor, not by
# ordinal: people keep editing while text streams in, and a block someone
# inserts above would otherwise move the target.
module StreamingBlocks
  private

  def new_paragraph
    @paragraph_text = +""
    para = nil
    change do
      para = new_block(Y::Lexical::PARAGRAPH_ATTRIBUTES)
      para.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES) # the text node an editor shows the words in
    end
    track(para)
    para
  end

  # A new top-level block goes after the last one this writer made, wherever
  # that block is now. The first goes after `after:`, or at `at:`, or at the end.
  def new_block(attributes)
    root = @doc.get_xml_text("root")
    at = next_ordinal
    block = at ? root.insert_xml_text(at, attributes) : root.push_xml_text(attributes)
    @last = BlockAnchor.new(@doc, block)
    block
  end

  def next_ordinal
    if @last
      last = @last.ordinal
      last ? last + 1 : @at
    elsif @after
      after = @after.ordinal
      after ? after + 1 : @at
    else
      @at
    end
  end

  # Text goes into the block this anchor finds; an item is found through its list.
  def track(top, item: nil)
    @anchor = BlockAnchor.new(@doc, top)
    @item = item
  end

  def current_block
    top = @anchor&.block
    return top unless top && @item

    top.xml_text(@item)
  end

  def new_heading
    level = [@line[/\A#+/].length, 6].min
    block = nil
    change do
      block = new_block(Y::Lexical.heading_attributes("h#{level}"))
      block.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
    end
    track(block)
    @paragraph = nil
    @prose_lines = 0
    block
  end

  def new_item(ordered: false)
    @list = nil if @list && @list_ordered != ordered # a numbered list after a bulleted one is a new list
    @list_ordered = ordered
    item = nil
    index = nil
    change do
      list = @list&.block
      unless list
        list = new_block(Y::Lexxy.list_attributes(ordered: ordered))
        @list = BlockAnchor.new(@doc, list)
      end
      index = list.xml_text_count
      item = list.push_xml_text(Y::Lexxy.list_item_attributes(index + 1))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
    end
    track(@list.block, item: index)
    item
  end
end
