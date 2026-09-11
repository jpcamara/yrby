# frozen_string_literal: true

# Applies an edit plan to a Lexical document in place, visibly: for each
# operation it highlights the block, then types the new text in at a
# model-like pace so people see the change happen. Operations refer to
# top-level blocks by ordinal as they were when the plan was made; the editor
# applies them from the highest ordinal down, so earlier ordinals stay valid.
#
#   plan = [{ "op" => "replace", "block" => 2, "text" => "..." },
#           { "op" => "insert_after", "block" => 2, "text" => "- a task\n- another" },
#           { "op" => "delete", "block" => 5 },
#           { "op" => "heading", "block" => 0, "level" => 2 }]
#   DocumentEditor.new(doc, flush: flush, presence: self).apply(plan)
class DocumentEditor
  OPS = %w[replace insert_after delete heading].freeze

  # `undo` is the plan that puts the document back: steps addressed by anchor,
  # in the order to run them. Pass it to `revert`.
  Result = Data.define(:applied, :skipped, :undo)

  # `presence` responds to show(status, block) and follow(block), or is nil.
  # `avoid:` ordinals of blocks people are writing in; edits to them are skipped.
  # `anchors:` are Y::Anchors made when the plan's block numbers were, one
  # per block; without them anchors are made when apply starts.
  def initialize(doc, flush:, presence: nil, pace: StubReviewer::PACE, avoid: [], anchors: nil)
    @doc = doc
    @flush = flush
    @presence = presence
    @pace = pace
    @avoid = avoid
    @anchors = anchors
  end

  STRUCTURED = /\A(?:[-*]\s|\d+[.)]\s|#)/ # a list item or a heading: a block of another kind

  # Each edit names a block by the number it had in the plan; the block is
  # found again by anchor right before the edit, since people keep editing
  # while the agent works. An edit whose block is gone is skipped.
  def apply(plan)
    applied = 0
    skipped = 0
    @writer = nil
    @undo = []
    normalize(plan).each do |edit|
      anchor = anchor_for(edit["block"])
      ordinal = anchor && @doc.block_at(anchor)
      if ordinal.nil? || @avoid.include?(edit["block"])
        skipped += 1
        next
      end
      send(edit["op"], edit.merge("block" => ordinal, "plan_block" => edit["block"]), anchor)
      applied += 1
    end
    @writer&.finish
    Result.new(applied: applied, skipped: skipped, undo: @undo)
  end

  # Run an undo plan from an earlier `apply`. Every step finds its block by
  # anchor, so it still works after people edited around it; a step whose
  # block is gone is skipped and counted.
  def revert(steps)
    applied = 0
    skipped = 0
    Array(steps).each do |step|
      done = case step["op"]
             when "remove" then remove(step)
             when "restore" then restore(step)
             when "restore_text" then restore_text(step)
             else 0
             end
      done.positive? ? applied += 1 : skipped += 1
    end
    Result.new(applied: applied, skipped: skipped, undo: [])
  end

  private

  # What a block is now, enough to put it back: attributes and text.
  def snapshot(block)
    { "attributes" => block.attributes, "text" => block.text }
  end

  def anchor_before(ordinal)
    root.xml_text(ordinal - 1).anchor if ordinal.positive?
  end

  # Undo steps run in the order given; a later edit's steps go first. A
  # removal with nothing to remove is not a step.
  def undo_first(*steps)
    steps = steps.reject { |s| s["op"] == "remove" && s["anchors"].empty? }
    @undo.unshift(*steps)
  end

  def created_since(count)
    @writer ? @writer.created.drop(count) : []
  end

  # Returns how many of the blocks were still there to remove.
  def remove(step)
    Array(step["anchors"]).reverse_each.count do |anchor|
      block = @doc.find(anchor)
      next false unless block

      @presence&.show("removing what I added", block)
      sleep [@pace * 4, 0.4].max
      at = @doc.block_at(anchor)
      change { root.delete_xml_text(at) } if at
      true
    end
  end

  # Put a block back where the block that took its place is now (`before`),
  # else after the block it followed (`after`), else at the end if those are
  # gone, else at the start; with its attributes and text. A list gets its
  # items back.
  def restore(step)
    at = restore_ordinal(step)
    attributes = step["attributes"].to_h
    text = step["text"].to_s
    change do
      block = root.insert_xml_text(at, attributes)
      case attributes["__type"]
      when "list"
        text.lines.map(&:chomp).each_with_index do |line, i|
          item = block.push_xml_text(Y::Lexxy.list_item_attributes(i + 1))
          item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
          item.insert(1, line)
        end
      when "quote"
        para = block.push_xml_text(Y::Lexical::PARAGRAPH_ATTRIBUTES)
        para.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
        para.insert(1, text)
      else
        marker = attributes["__type"] == "code" ? Y::Lexical::CODE_TEXT_ATTRIBUTES : Y::Lexical::TEXT_ATTRIBUTES
        block.insert_embed(0, marker)
        block.insert(1, text)
      end
    end
    @presence&.show("putting a block back", root.xml_text(at))
    1
  end

  def restore_ordinal(step)
    before = step["before"] && @doc.block_at(step["before"])
    return before if before

    after = step["after"] && @doc.block_at(step["after"])
    return after + 1 if after

    step["before"] || step["after"] ? root.xml_text_count : 0
  end

  def restore_text(step)
    block = @doc.find(step["anchor"])
    return 0 unless block

    @presence&.show("putting the text back", block)
    change { block.clear }
    type_into(step["anchor"], step["text"])
    1
  end

  def root = @doc.get_xml_text("root")

  def anchor_for(plan_block)
    return @anchors[plan_block] if @anchors

    root.xml_text(plan_block).anchor if plan_block < root.xml_text_count
  end

  # Valid edits, highest block first; for one block, a rewrite comes before an
  # insertion after it, and a deletion last.
  def normalize(plan)
    order = { "heading" => 0, "replace" => 1, "insert_after" => 2, "delete" => 3 }
    Array(plan).select { |e| OPS.include?(e["op"]) && e["block"].is_a?(Integer) && e["block"] >= 0 }
               .sort_by { |e| [-e["block"], order[e["op"]]] }
  end

  # Rewrite a block's text in place. Text that is a list item or a heading
  # makes the block another kind: the old block goes and the writer types the
  # new one at its position, so a following insert_after can continue it.
  def replace(edit, anchor)
    block = @doc.find(anchor)
    @presence&.show("rewriting block #{edit["block"]}", block)
    was = snapshot(block)
    if edit["text"].to_s.match?(STRUCTURED)
      at = edit["block"]
      before = anchor_before(at)
      change { root.delete_xml_text(at) }
      made = @writer ? @writer.created.size : 0
      type_blocks(edit["text"], at: 0, after: before, block: edit["plan_block"])
      created = created_since(made)
      undo_first({ "op" => "restore", "before" => created.first, "after" => before, **was },
                 { "op" => "remove", "anchors" => created })
    else
      change { block.clear }
      type_into(anchor, edit["text"])
      undo_first({ "op" => "restore_text", "anchor" => anchor, "text" => was["text"] })
    end
  end

  # New blocks after a block; each line of text is one block, "- " a bullet.
  # Continues the writer a replace on the same block left open, so a list
  # started there keeps numbering.
  def insert_after(edit, anchor)
    made = @writer && @writer_block == edit["plan_block"] ? @writer.created.size : 0
    if @writer && @writer_block == edit["plan_block"]
      type_blocks("\n#{edit["text"]}", block: edit["plan_block"])
    else
      @presence&.show("adding after block #{edit["block"]}", @doc.find(anchor))
      type_blocks(edit["text"], after: anchor, block: edit["plan_block"])
    end
    undo_first({ "op" => "remove", "anchors" => created_since(made) })
  end

  # Type structured text through a StreamingWriter, one block per line.
  def type_blocks(text, block:, at: nil, after: nil)
    unless @writer && @writer_block == block
      @writer&.finish
      @writer = StreamingWriter.new(@doc, flush: @flush, at: at, after: after)
      @writer_block = block
    end
    "#{text}\n".split(/(?<= )|(?<=\n)/).each do |piece|
      @writer.feed(piece)
      @presence&.follow(@writer.block) if @writer.block
      sleep @pace
    end
  end

  def delete(edit, anchor)
    close_writer
    block = @doc.find(anchor)
    @presence&.show("removing block #{edit["block"]}", block)
    sleep [@pace * 6, 0.6].max
    at = @doc.block_at(anchor)
    return unless at

    following = root.xml_text(at + 1).anchor if at + 1 < root.xml_text_count
    undo_first({ "op" => "restore", "before" => following, "after" => anchor_before(at), **snapshot(block) })
    change { root.delete_xml_text(at) }
  end

  # A block becomes a heading: a new heading with its text takes its place.
  def heading(edit, anchor)
    close_writer
    at = edit["block"]
    block = @doc.find(anchor)
    @presence&.show("making block #{at} a heading", block)
    text = block.text
    level = (edit["level"] || 2).to_i.clamp(1, 6)
    was = snapshot(block)
    made = nil
    change do
      at = @doc.block_at(anchor)
      heading = root.insert_xml_text(at + 1, Y::Lexical.heading_attributes("h#{level}"))
      Y::Lexical.write_runs(heading, text)
      made = heading.anchor # before the deletion below moves the handle's ordinal
      root.delete_xml_text(at)
    end
    undo_first({ "op" => "restore", "before" => made, **was },
               { "op" => "remove", "anchors" => [made] })
  end

  def close_writer
    @writer&.finish
    @writer = nil
  end

  # Type text into an emptied block a word at a time, caret following. The
  # block is found again for every word; if someone removes it, the rest of
  # the text is dropped with it.
  def type_into(anchor, text)
    close_writer
    change { @doc.find(anchor)&.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES) }
    text.to_s.split(/(?<= )/).each do |word|
      break unless (block = @doc.find(anchor))

      change { block.insert(block.length, word) }
      @presence&.follow(block)
      sleep @pace
    end
    return unless (block = @doc.find(anchor))

    formatted = Y::Lexical::Markdown.runs(text.to_s)
    change { Y::Lexical.replace_runs(block, formatted) } if text.to_s.match?(Y::Lexical::Markdown::INLINE)
  end

  def change(&)
    update = @doc.diff(&)
    @flush.call(update) if update
  end
end
