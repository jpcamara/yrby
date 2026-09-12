# frozen_string_literal: true

# Applies a plan of paragraph edits to a markdown Y.Text: replace, insert
# after, delete, by paragraph number as the model saw them. Edits go highest
# paragraph first so earlier numbers stay valid, and each is one change.
class MarkdownEditor
  OPS = %w[replace insert_after delete heading].freeze

  # Options: `avoid:` paragraph numbers to skip, `only:` a range the plan
  # may touch, `presence:` a callable (status, from, to) to highlight.
  def initialize(doc, text, flush:, **options)
    @doc = doc
    @text = text
    @flush = flush
    @avoid = options.fetch(:avoid, [])
    @presence = options[:presence]
    @only = options[:only]
  end

  def apply(plan)
    applied = 0
    order = { "heading" => 0, "replace" => 1, "insert_after" => 2, "delete" => 3 }
    Array(plan).select { |e| OPS.include?(e["op"]) && e["block"].is_a?(Integer) && e["block"] >= 0 }
               .sort_by { |e| [-e["block"], order[e["op"]]] }.each do |edit|
      next if @avoid.include?(edit["block"]) || (@only && !@only.cover?(edit["block"]))

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

  # Only the part that differs is retyped: a fixed word is a small change
  # in place, not a paragraph wiped and written again.
  def replace(paragraph, edit)
    from = MarkdownDoc.line_start(@text.to_s, paragraph.first_line)
    old_text = paragraph.text
    new_text = edit["text"].to_s.strip
    head, old_mid, new_mid = differing_span(old_text, new_text)
    at = from + head.bytesize
    change { @text.delete(at, old_mid.bytesize) } if old_mid.bytesize.positive?
    type(at, new_mid) unless new_mid.empty?
  end

  # The common start and end of two strings, and what lies between.
  def differing_span(old_text, new_text)
    a = old_text.chars
    b = new_text.chars
    prefix = common_length(a, b)
    suffix = common_length(a[prefix..].reverse, b[prefix..].reverse)
    [a[0, prefix].join, a[prefix, a.length - prefix - suffix].join, b[prefix, b.length - prefix - suffix].join]
  end

  def common_length(left, right)
    n = 0
    n += 1 while n < left.length && n < right.length && left[n] == right[n]
    n
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
