# frozen_string_literal: true

# Applies a plan of paragraph edits to a markdown Y.Text: replace, insert
# after, delete, by paragraph number as the model saw them. Edits go highest
# paragraph first so earlier numbers stay valid, and each is one change.
class MarkdownEditor
  OPS = %w[replace insert_after delete heading].freeze

  def initialize(doc, text, flush:, avoid: [], presence: nil)
    @doc = doc
    @text = text
    @flush = flush
    @avoid = avoid
    @presence = presence
  end

  def apply(plan)
    applied = 0
    order = { "heading" => 0, "replace" => 1, "insert_after" => 2, "delete" => 3 }
    Array(plan).select { |e| OPS.include?(e["op"]) && e["block"].is_a?(Integer) && e["block"] >= 0 }
               .sort_by { |e| [-e["block"], order[e["op"]]] }.each do |edit|
      next if @avoid.include?(edit["block"])

      paragraphs = MarkdownDoc.paragraphs(@text.to_s)
      p = paragraphs[edit["block"]] or next
      announce(edit, p)
      send(edit["op"], p, edit)
      applied += 1
    end
    applied
  end

  private

  # Select the paragraph about to change, and give people a moment to see it.
  def announce(edit, paragraph)
    return unless @presence

    @presence.call("#{edit["op"].tr("_", " ")} paragraph #{edit["block"]}",
                   MarkdownDoc.line_start(@text.to_s, paragraph.first_line),
                   MarkdownDoc.line_end(@text.to_s, paragraph.last_line))
    sleep 0.4
  end

  def replace(paragraph, edit)
    from = MarkdownDoc.line_start(@text.to_s, paragraph.first_line)
    change { @text.delete(from, paragraph.text.bytesize) }
    type(from, edit["text"].to_s.strip)
  end

  def insert_after(paragraph, edit)
    at = MarkdownDoc.line_end(@text.to_s, paragraph.last_line)
    change { @text.insert(at, "\n\n") }
    type(at + 2, edit["text"].to_s.strip)
  end

  # Type text in at the agent's pace, the written part selected as it grows.
  def type(at, text)
    writer = MarkdownWriter.new(@doc, @text, flush: @flush, at: at)
    pacer = Pacer.new { |piece| writer.feed(piece) }
    pacer.feed(text)
    while pacer.pending?
      pacer.drain
      @presence&.call("writing", writer.start_index || writer.index, writer.index)
      sleep 0.03
    end
  end

  def delete(paragraph, _edit)
    from = MarkdownDoc.line_start(@text.to_s, paragraph.first_line)
    len = paragraph.text.bytesize
    len += 2 if @text.to_s.byteslice(from + len, 2) == "\n\n"
    change { @text.delete(from, len) }
  end

  def heading(paragraph, edit)
    level = (edit["level"] || 2).to_i.clamp(1, 6)
    from = MarkdownDoc.line_start(@text.to_s, paragraph.first_line)
    change { @text.insert(from, "#{"#" * level} ") }
  end

  def change(&)
    update = @doc.diff(&)
    @flush.call(update) if update
  end
end
