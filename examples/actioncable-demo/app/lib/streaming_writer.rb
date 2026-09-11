# frozen_string_literal: true

# Types a stream of text into a Lexical document as it arrives. Prose goes into
# a paragraph; a line that starts with "- " or "* " goes into a bulleted list,
# one item per line. Every piece of text is inserted the moment it is known,
# so an open editor shows the words appearing. Each insert is one diff,
# handed to `flush` to record and broadcast.
#
# A line's kind is decided from its first two characters, so the writer holds
# at most that much back; the rest of the line streams through.
class StreamingWriter
  include StreamingBlocks

  # `at:` is the ordinal the first block goes in at (before the block that is
  # there now); without it blocks go at the end.
  def initialize(doc, flush:, at: nil)
    @doc = doc
    @flush = flush
    @at = at
    @paragraph = nil
    @list = nil
    @block = nil   # the block text is currently going into
    @line = +""    # the current line, until its kind is known
    @decided = false
    @prose_lines = 0
    @paragraph_text = +""
  end

  # The block that last received text, for a caret to follow, and the list
  # the bullets went into, if any.
  attr_reader :block, :list

  # One insert per chunk (per newline-free run of it), not per character: a
  # word from the stub or a token from a model is one update.
  def feed(chunk)
    text = chunk.to_s
    until text.empty?
      newline = text.index("\n")
      segment = newline ? text[0...newline] : text
      take(segment) unless segment.empty?
      end_line if newline
      text = newline ? text[(newline + 1)..] : ""
    end
  end

  def finish
    end_line unless @line.empty? && @decided
  end

  private

  def take(segment)
    if @decided
      write(segment)
    else
      @line << segment
      decide if @line.length >= 3 # "- x", "1. x", "# x": enough to tell
    end
  end

  # Three characters in, the line's kind is known. Route what is buffered
  # (which may already be longer, if a chunk was long).
  def decide
    @decided = true
    if @line.start_with?("- ", "* ")
      @block = new_item
      write(@line[2..])
    elsif @line.start_with?("#")
      @block = new_heading
      write(@line.sub(/\A#+\s*/, ""))
    elsif @line.match?(/\A\d+[.)]\s/)
      @block = new_item(ordered: true)
      write(@line.sub(/\A\d+[.)]\s+/, ""))
    else
      # Prose after a list starts a new paragraph rather than joining the one
      # above the list. Lines of one paragraph are joined with a space.
      if @list
        @paragraph = nil
        @list = nil
        @prose_lines = 0
        @paragraph_text = +""
      end
      @block = @paragraph ||= new_paragraph
      @prose_lines += 1
      write(@prose_lines == 1 ? @line : " #{@line}")
    end
  end

  def end_line
    decide unless @decided || @line.empty? # a one-character line is prose
    format_paragraph if @block.equal?(@paragraph) && @decided
    @line = +""
    @decided = false
  end

  # Inline markdown (**bold**, *italic*, `code`, [links](url)) streams through
  # as typed; when the line completes, the paragraph is rewritten as formatted
  # runs. The words were already on screen, so this is a small fix-up.
  def format_paragraph
    text = @paragraph_text
    return unless text.match?(Y::Lexical::Markdown::INLINE)

    change { Y::Lexical.replace_runs(@paragraph, Y::Lexical::Markdown.runs(text)) }
  end

  def write(text)
    return if text.empty?

    @paragraph_text << text if @block.equal?(@paragraph)
    block = @block
    change { block.insert(block.length, text) }
  end

  # A paragraph starts with its text node's marker; the characters follow it.
  # Without the marker an editor has no text node to show them in.
  def change(&)
    update = @doc.diff(&)
    @flush.call(update) if update
  end
end
