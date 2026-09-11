# frozen_string_literal: true

# Streams text into a Y.Text at a point that keeps its place while other
# people edit above it. The point is a relative position with "after"
# association: it names the character after the insertion gap, so text the
# writer inserts lands before it and the next chunk goes right after. At the
# end of the document it names the text itself.
class MarkdownWriter
  def initialize(doc, text, flush:, at:)
    @doc = doc
    @text = text
    @flush = flush
    @position = text.relative_position(at, assoc: :after)
    @start = text.relative_position(at, assoc: :before)
    @written = +""
  end

  attr_reader :written

  def index = @doc.index_at(@position, @text.root_name) || @text.length

  # Where the written text begins, as of now.
  def start_index = @doc.index_at(@start, @text.root_name)

  def feed(chunk)
    chunk = chunk.to_s
    return if chunk.empty?

    at = index
    update = @doc.diff { @text.insert(at, chunk) }
    @written << chunk
    @flush.call(update) if update
  end

  def finish = nil
end
