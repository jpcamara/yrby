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
  Result = Data.define(:applied, :skipped)

  # `presence` responds to show(status, block) and follow(block), or is nil.
  def initialize(doc, flush:, presence: nil, pace: StubReviewer::PACE)
    @doc = doc
    @flush = flush
    @presence = presence
    @pace = pace
  end

  STRUCTURED = /\A(?:[-*]\s|\d+[.)]\s|#)/ # a list item or a heading: a block of another kind

  def apply(plan)
    applied = 0
    skipped = 0
    @writer = nil
    normalize(plan).each do |edit|
      if edit["block"] >= root.xml_text_count
        skipped += 1
        next
      end
      send(edit["op"], edit)
      applied += 1
    end
    @writer&.finish
    Result.new(applied: applied, skipped: skipped)
  end

  private

  def root = @doc.get_xml_text("root")

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
  def replace(edit)
    block = root.xml_text(edit["block"])
    @presence&.show("rewriting block #{edit["block"]}", block)
    if edit["text"].to_s.match?(STRUCTURED)
      change { root.delete_xml_text(edit["block"]) }
      type_blocks(edit["text"], at: edit["block"], block: edit["block"])
    else
      change { block.clear }
      type_into(block, edit["text"])
    end
  end

  # New blocks after a block; each line of text is one block, "- " a bullet.
  # Continues the writer a replace on the same block left open, so a list
  # started there keeps numbering.
  def insert_after(edit)
    if @writer && @writer_block == edit["block"]
      type_blocks("\n#{edit["text"]}", block: edit["block"])
    else
      @presence&.show("adding after block #{edit["block"]}", root.xml_text(edit["block"]))
      type_blocks(edit["text"], at: edit["block"] + 1, block: edit["block"])
    end
  end

  # Type structured text through a StreamingWriter, one block per line.
  def type_blocks(text, block:, at: nil)
    unless @writer && @writer_block == block
      @writer&.finish
      @writer = StreamingWriter.new(@doc, flush: @flush, at: at)
      @writer_block = block
    end
    "#{text}\n".split(/(?<= )|(?<=\n)/).each do |piece|
      @writer.feed(piece)
      @presence&.follow(@writer.block) if @writer.block
      sleep @pace
    end
  end

  def delete(edit)
    close_writer
    @presence&.show("removing block #{edit["block"]}", root.xml_text(edit["block"]))
    sleep [@pace * 6, 0.6].max
    change { root.delete_xml_text(edit["block"]) }
  end

  # A block becomes a heading: a new heading with its text takes its place.
  def heading(edit)
    close_writer
    at = edit["block"]
    block = root.xml_text(at)
    @presence&.show("making block #{at} a heading", block)
    text = block.text
    level = (edit["level"] || 2).to_i.clamp(1, 6)
    change do
      heading = root.insert_xml_text(at + 1, Y::Lexical.heading_attributes("h#{level}"))
      Y::Lexical.write_runs(heading, text)
      root.delete_xml_text(at)
    end
  end

  def close_writer
    @writer&.finish
    @writer = nil
  end

  # Type text into an emptied block a word at a time, caret following.
  def type_into(block, text)
    close_writer
    change { block.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES) }
    text.to_s.split(/(?<= )/).each do |word|
      change { block.insert(block.length, word) }
      @presence&.follow(block)
      sleep @pace
    end
    formatted = Y::Lexical::Markdown.runs(text.to_s)
    change { Y::Lexical.replace_runs(block, formatted) } if text.to_s.match?(Y::Lexical::Markdown::INLINE)
  end

  def change(&)
    update = @doc.diff(&)
    @flush.call(update) if update
  end
end
