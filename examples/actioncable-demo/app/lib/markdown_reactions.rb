# frozen_string_literal: true

# How MarkdownAgent reacts to what people write: a line addressed to it is a
# request or a question; anything else is a change to consider, unless it is
# inside its own list or a section it drafted.
module MarkdownReactions
  ANSWER_PACE = 140 # characters per second: an answer is a reply, not a draft to watch

  private

  def react_to(first, last)
    ls = MarkdownDoc.lines(text)
    line = (first..[last, ls.length - 1].min).find { |i| MarkdownDoc.agent_line?(ls[i].to_s) }
    return contribute(first, last) unless line

    request = ls[line].strip
    case request
    when /\A@agent\s+undo\b/i then undo_last(line)
    when /\A@agent\s+(take|pause|resume|continue|stop)\b/i then handoff(line, request)
    when /\A@agent\s+draft\s+(this|the|here)\b/i then draft_here(line)
    when /\A@agent\b/i
      if scoped_request?(request)
        edit_selection(line, request)
      elsif !@answered.include?(request)
        answer(line, request)
      end
    end
  end

  def contribute(first, last)
    paragraphs = MarkdownDoc.paragraphs(text)
    changed = paragraphs.select { |p| p.last_line >= first && p.first_line <= last }.map(&:index)
    return if changed.empty? || !settled?(paragraphs[changed.last]) || mine?(changed, paragraphs)

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
    reg = region_of_plan(result.edits)
    applied = MarkdownEditor.new(@doc, @text, flush: flush, avoid: avoid, presence: highlight).apply(result.edits)
    return unless applied.positive?

    remember_undo("what I added after your change", reg) if reg
    present("added to what you wrote", @text.length, detail: result.note.presence)
    note_in_review("Added after your change: #{result.note.presence || "a line"}")
  end

  # The byte range a plan will touch, as a region to undo, or nil.
  def region_of_plan(plan)
    paragraphs = MarkdownDoc.paragraphs(text)
    blocks = plan.filter_map { |e| e["block"] if e["block"].is_a?(Integer) && paragraphs[e["block"]] }
    return if blocks.empty?

    region(MarkdownDoc.line_start(text, paragraphs[blocks.min].first_line),
           MarkdownDoc.line_end(text, paragraphs[blocks.max].last_line))
  end

  def scoped_request?(request)
    !request.end_with?("?") && request.match?(/\b(this|these|that|the selection|selected)\b/i)
  end

  # "@agent rewrite this in one sentence": the paragraphs the author last
  # selected (or the one above the line) are the only ones the plan may
  # touch. The request line goes; the rewrite is typed in its place.
  def edit_selection(line, request)
    range = selection_for(line)
    Rails.logger.debug { "agent: scope for line #{line}: #{range.inspect}" }
    range ||= paragraph_above(line)
    return answer(line, request) unless range

    instruction = request.sub(/\A@agent\s*:?\s*/i, "").strip
    from, to = take_request(line, range)
    return present("what you selected is gone", @last_index) unless from

    rewrite(*paragraph_span(from, to), instruction)
    @changes.clear
  end

  # Paragraph numbers covering a byte range.
  def paragraph_span(from, to)
    paragraphs = MarkdownDoc.paragraphs(text)
    first = paragraphs.index { |p| MarkdownDoc.line_end(text, p.last_line) > from } || (paragraphs.length - 1)
    last = paragraphs.rindex { |p| MarkdownDoc.line_start(text, p.first_line) < to } || first
    [first, [last, first].max]
  end

  def rewrite(first, last, instruction)
    paragraphs = MarkdownDoc.paragraphs(text)
    reg = region(MarkdownDoc.line_start(text, paragraphs[first].first_line),
                 MarkdownDoc.line_end(text, paragraphs[last].last_line))
    present("rewriting what you selected", *region_bounds(reg), sticky: true)
    plan = @reviewer.edits(instruction, paragraphs.map(&:text), only: first..last)
    highlight = ->(status, a, b) { present(status, a, b, sticky: true) }
    applied = MarkdownEditor.new(@doc, @text, flush: flush, presence: highlight, only: first..last).apply(plan)
    label = first == last ? "the rewrite of paragraph #{first}" : "the rewrite of paragraphs #{first} to #{last}"
    remember_undo(label, reg)
    present("rewrote #{applied} #{applied == 1 ? "paragraph" : "paragraphs"} you selected", *region_bounds(reg))
    note_in_review("Rewrote what you selected: #{instruction}")
  end

  # The paragraph just above a line, as a byte range, or nil.
  def paragraph_above(line)
    p = MarkdownDoc.paragraphs(text).select { |x| x.last_line < line }.max_by(&:last_line) or return
    [MarkdownDoc.line_start(text, p.first_line), MarkdownDoc.line_end(text, p.last_line)]
  end

  # Take the request line out, keeping the scope by anchor across the deletion.
  def take_request(line, range)
    from, to = range
    start = @text.relative_position(from, assoc: :before)
    finish = @text.relative_position(to, assoc: :after)
    present("taking your request", MarkdownDoc.line_start(text, line), MarkdownDoc.line_end(text, line), sticky: true)
    delete_line(line)
    [@doc.index_at(start, @text.root_name), @doc.index_at(finish, @text.root_name)]
  end

  # "@agent undo": put back whatever the agent did last.
  def undo_last(line)
    delete_line(line)
    last = (@undos ||= []).pop
    return present("nothing of mine to undo", @last_index) unless last

    if revert(last[:region])
      @reviewer.remember("Undid #{last[:label]}") if @reviewer.respond_to?(:remember)
      present("undid #{last[:label]}", @last_index)
      note_in_review("Undid #{last[:label]}.")
    else
      present("could not undo #{last[:label]}", @last_index, detail: "that part of the document is gone")
    end
    @changes.clear
  end

  # A change is worth a look once it reads finished: the paragraph ends with
  # punctuation, or the person's caret has left it.
  def settled?(paragraph)
    text = paragraph.text.strip
    return true if text.empty? || text.match?(/[.!?:)\]"”»]\s*\z/) || text.match?(/\A[-*#>]/)

    lines = occupied_lines
    Rails.logger.debug { "agent: gate #{paragraph.first_line}..#{paragraph.last_line} occupied #{lines.inspect}" }
    lines.none? { |l| l.between?(paragraph.first_line, paragraph.last_line) }
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
    reg = region(at, at)
    writer = MarkdownWriter.new(@doc, @text, flush: flush, at: at)
    writer.feed("\n\n")
    stream_into(writer, "answering", pace: ANSWER_PACE) do |emit|
      @reviewer.answer(question, text, &without_headings(emit))
    end
    remember_undo("my answer", reg)
    present("answered", writer.index)
  end

  # A reply is not a section: "#" at the start of a line is dropped as the
  # chunks stream through.
  def without_headings(emit)
    at_line_start = true
    lambda do |chunk|
      out = +""
      chunk.to_s.each_char do |c|
        next if at_line_start && (c == "#" || (c == " " && out.empty? && chunk.start_with?("#")))

        out << c
        at_line_start = c == "\n"
      end
      emit.call(out) unless out.empty?
    end
  end

  # Feed a stream of chunks into `writer`; the caret follows the text.
  # The model's chunks go through a pacer so the text arrives at a steady
  # pace rather than in the bursts the model produces them in.
  def stream_into(writer, status, pace: Pacer::RATE)
    since = 0
    pacer = Pacer.new(rate: pace) { |piece| writer.feed(piece) }
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
