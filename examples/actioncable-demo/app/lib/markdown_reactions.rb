# frozen_string_literal: true

# How MarkdownAgent reacts to what people write: a line addressed to it is a
# request or a question; anything else is a change to consider, unless it is
# inside its own list or a section it drafted.
module MarkdownReactions
  private

  def react_to(first, last)
    ls = MarkdownDoc.lines(text)
    line = (first..[last, ls.length - 1].min).find { |i| MarkdownDoc.agent_line?(ls[i].to_s) }
    return contribute(first, last) unless line

    request = ls[line].strip
    case request
    when /\A@agent\s+(take|pause|resume|continue|stop)\b/i then handoff(line, request)
    when /\A@agent\s+draft\s+(this|the|here)\b/i then draft_here(line)
    when /\A@agent\b/i then answer(line, request) unless @answered.include?(request)
    end
  end

  def contribute(first, last)
    paragraphs = MarkdownDoc.paragraphs(text)
    changed = paragraphs.select { |p| p.last_line >= first && p.first_line <= last }.map(&:index)
    return if changed.empty? || mine?(changed, paragraphs)

    avoid = leave_alone(paragraphs)
    here = MarkdownDoc.line_end(text, paragraphs[changed.last].last_line)
    present("thinking about your change", here, sticky: true)
    result = @reviewer.consider(changed, avoid, paragraphs.map(&:text))
    if result.edits.empty?
      present("left it alone", here, detail: result.note.presence)
    else
      apply_contribution(result, avoid)
    end
    @changes.clear
  end

  def leave_alone(paragraphs)
    avoid = (occupied_paragraphs(paragraphs) | my_paragraphs(paragraphs)).sort
    Rails.logger.info("agent: leaving alone #{avoid.inspect}, people #{people_here.inspect}")
    avoid
  end

  def apply_contribution(result, avoid)
    highlight = ->(status, from, to) { present(status, from, to, sticky: true) }
    applied = MarkdownEditor.new(@doc, @text, flush: flush, avoid: avoid, presence: highlight).apply(result.edits)
    return unless applied.positive?

    present("added to what you wrote", @text.length, detail: result.note.presence)
    note_in_review("Added after your change: #{result.note.presence || "a line"}")
  end

  # A change inside a section the agent drafted hands that section over; a
  # change to its task list is new work. Either way, nothing to consider.
  def mine?(changed, paragraphs)
    edited_my_section?(changed, paragraphs) || edited_my_list?(changed, paragraphs)
  end

  def edited_my_section?(changed, paragraphs)
    ranges = Array(@sections).filter_map { |s| section_range(s) }
    hit = changed.find { |i| ranges.any? { |(a, b, _)| paragraphs[i].first_line >= a && paragraphs[i].last_line <= b } }
    return false unless hit

    title = ranges.find { |(a, b, _)| paragraphs[hit].first_line >= a && paragraphs[hit].last_line <= b }[2]
    @reviewer.remember("Someone edited my draft of \"#{title}\"; that section is theirs now")
    present("noted your edit to my draft", MarkdownDoc.line_end(text, paragraphs[hit].last_line),
            detail: "\"#{title}\" is yours now; I will leave it alone")
    true
  end

  def edited_my_list?(changed, paragraphs)
    tasks.map(&:line)
    return false unless changed.any? do |i|
      (paragraphs[i].first_line..paragraphs[i].last_line).any? do |l|
        tasks.include?(l)
      end
    end

    @next_scan = 0
    present("saw your change to my list", MarkdownDoc.line_end(text, paragraphs[changed.last].last_line))
    true
  end

  def occupied_paragraphs(paragraphs)
    lines = occupied_lines
    paragraphs.select { |p| lines.any? { |l| l.between?(p.first_line, p.last_line) } }.map(&:index)
  end

  def my_paragraphs(paragraphs)
    ranges = Array(@sections).filter_map { |s| section_range(s) }
    ranges << [review_line, MarkdownDoc.lines(text).length - 1] if review_line
    task_lines = tasks.map(&:line)
    paragraphs.select do |p|
      ranges.any? { |(a, b, _)| p.first_line >= a && p.last_line <= b } ||
        (p.first_line..p.last_line).any? { |l| task_lines.include?(l) }
    end.map(&:index)
  end

  # A drafted section as [first_line, last_line, title], found by its heading anchor.
  def section_range(entry)
    i = @doc.index_at(entry[:heading], @text.root_name) or return
    line = MarkdownDoc.line_of_index(text, i)
    s = MarkdownDoc.section_at(text, line) or return
    [s.line, s.last_line, entry[:title]]
  end

  def review_line
    i = @review && @doc.index_at(@review, @text.root_name) or return
    MarkdownDoc.line_of_index(text, i)
  end

  def answer(line, question)
    @answered << question
    at = MarkdownDoc.line_end(text, line)
    present("answering", at, sticky: true)
    writer = MarkdownWriter.new(@doc, @text, flush: flush, at: at)
    writer.feed("\n\n")
    stream_into(writer, "answering") { |emit| @reviewer.answer(question, text, &emit) }
    present("answered", writer.index)
  end

  # Feed a stream of chunks into `writer`; the caret follows the text.
  # The model's chunks go through a pacer so the text arrives at a steady
  # pace rather than in the bursts the model produces them in.
  def stream_into(writer, status)
    since = 0
    pacer = Pacer.new { |piece| writer.feed(piece) }
    follow = lambda do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next unless now - since > 0.25

      present(status, writer.start_index || writer.index, writer.index, sticky: true)
      since = now
    end
    emit = lambda do |chunk|
      pacer.feed(chunk)
      while pacer.pending?
        pacer.drain
        follow.call
        sleep 0.03 if pacer.pending?
      end
    end
    yield emit
    pacer.flush
    writer.finish
  end
end
