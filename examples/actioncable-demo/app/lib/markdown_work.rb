# frozen_string_literal: true

# MarkdownAgent's own work: tasks from its list in the document, drafted
# where they point (a named section, or a new one at the end), one at a
# time after the review (AGENT_DRAFTS raises that), interleaved with
# reacting, yielding while someone is at the point being written.
module MarkdownWork
  SCAN_EVERY = 3 # seconds between looks at the list while idle
  MAX_DRAFTS = ENV.fetch("AGENT_DRAFTS", "1").to_i

  # One section being drafted: the task, an anchor on its list line, the
  # writer, the section heading's position and title, the region the draft
  # occupies (for undo), and the model stream.
  Draft = Data.define(:task, :anchor, :writer, :heading, :title, :region, :job) do
    def done? = job.finished?
  end

  # A task that asks for a change to what is there ("fix the spelling",
  # "tighten the intro", "rename X to Y") is an edit across the document,
  # not a new section.
  EDIT_TASK = /
    \b(fix|correct|tackle|clean\s+up|proofread|tighten|shorten|polish|rename|replace|remove|delete|reword|rephrase)\b
    |\b(grammar|spelling|typos?|consistent|consistency|punctuation)\b
  /ix
  DRAFT_TASK = /\A\s*(draft|write|add|create|outline|prepare)\b/i

  private

  def edit_task?(task) = !task.text.match?(DRAFT_TASK) && task.text.match?(EDIT_TASK)

  def drafts = (@drafts ||= [])

  def drafting? = drafts.any?

  def work_pending? = drafting? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (@next_scan || 0)

  def work_step
    return if @paused

    drafts.dup.each { |d| draft_step(d) }
    return if reviewing? || drafts.size >= MAX_DRAFTS

    pick_task if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (@next_scan || 0)
  rescue StandardError => e
    Rails.logger.warn("agent work failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}")
    abandon_drafts(e)
  end

  # Whatever went wrong, the tasks go back on the list unchecked and the
  # failure is said where people can see it. The drafts leave the list first
  # so stopping their streams does not count them as done.
  def abandon_drafts(error)
    stopped = drafts.dup
    drafts.clear
    stopped.each do |d|
      d.job.stop
      mark(d.task, :open, anchor: d.anchor)
      report_failure("drafting #{d.title}", error, "the task is back on the list")
    end
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  end

  def pick_task
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCAN_EVERY
    busy = occupied_lines
    task = tasks.find { |t| t.state == :open && !busy.include?(t.line) }
    return unless task

    unless @last_presence&.dig(:status) == "up next: #{section_title(task.text)}" # announce_next may have said so
      present("up next: #{section_title(task.text)}", @last_index,
              sticky: true, detail: "from your list; say @agent pause to hold me")
    end
    sleep 1.5 unless drafting?
    claim(task)
  end

  def announce_next
    return present(working_label, @last_index, sticky: true) if drafting?

    task = tasks.find { |t| t.state == :open }
    if task
      present("up next: #{section_title(task.text)}", @last_index, detail: "from your list")
    else
      present("listening", @last_index, sticky: true, detail: AgentWork::LISTENING)
    end
  end

  def claim(task)
    return run_edit_task(task) if edit_task?(task)

    anchor = task.line && @text.relative_position(MarkdownDoc.line_start(text, task.line))
    mark(task, :drafting)
    section = open_section(task)
    present("drafting #{section[:title]}", section[:writer].index, detail: took_detail(task, section), sticky: true)
    job = nil
    job = StreamJob.new(writer: section[:writer], label: section[:title], on_finish: -> { finish_draft(job) }) do |emit|
      @reviewer.draft(task.text, text, &emit)
    end
    drafts << Draft.new(task: task, anchor: anchor, writer: section[:writer], heading: section[:heading],
                        title: section[:title], region: section[:region], job: job)
  end

  # An edit task: a plan from the model over the whole document, applied in
  # place, leaving the task list itself alone. Runs in the loop like an
  # answer does.
  def run_edit_task(task)
    anchor = task.line && @text.relative_position(MarkdownDoc.line_start(text, task.line))
    mark(task, :drafting)
    present("working on: #{task.text}", @last_index, sticky: true, detail: "editing in place")
    applied = apply_edit_plan(*edit_plan(task), task)
    mark(task, :done, anchor: anchor)
    present("done: #{task.text}", @last_index, detail: changed_in_place(applied, "paragraph"))
    note_in_review("#{task.text}: changed #{applied} paragraphs in place.") if applied.positive?
    @next_scan = 0
  end

  # The model's plan for the task over the whole document, minus the
  # paragraphs that hold the task list itself.
  def edit_plan(task)
    paragraphs = MarkdownDoc.paragraphs(text)
    avoid = paragraphs.select { |p| tasks.any? { |t| t.line&.between?(p.first_line, p.last_line) } }.map(&:index)
    plan = @reviewer.edits("#{task.text}. Change only what this calls for and keep everything else word for word.",
                           paragraphs.map(&:text))
    [plan.reject { |e| avoid.include?(e["block"]) }, avoid]
  end

  def apply_edit_plan(plan, avoid, task)
    reg = region_of_plan(plan)
    highlight = ->(status, from, to) { present(status, from, to, sticky: true, log: false) }
    applied = MarkdownEditor.new(@doc, @text, flush: flush, avoid: avoid, presence: highlight).apply(plan)
    remember_undo("the edit: #{task.text}", reg) if reg && applied.positive?
    applied
  end

  def changed_in_place(count, unit)
    return "nothing needed changing" unless count.positive?

    "changed #{count} #{count == 1 ? unit : "#{unit}s"} in place"
  end

  def took_detail(task, section)
    return "drafting the section you pointed at" unless task.line

    where = section[:named] ? ", under #{section[:title]}" : ""
    "took \"#{task.text}\" from the list#{where}"
  end

  # The draft goes at the end of the named section when there is one, else
  # into a new section at the end.
  def open_section(task)
    section = task.under && MarkdownDoc.section(text, task.under)
    section ? open_named_section(section) : open_new_section(task)
  end

  def open_named_section(section)
    heading = @text.relative_position(MarkdownDoc.line_start(text, section.line))
    at = MarkdownDoc.line_end(text, MarkdownDoc.section_content_end(text, section))
    region = region(at, at)
    writer = MarkdownWriter.new(@doc, @text, flush: flush, at: at)
    writer.feed("\n\n")
    { title: section.title, heading: heading, region: region, writer: writer, named: true }
  end

  def open_new_section(task)
    title = section_title(task.text)
    ensure_trailing_newlines(2)
    heading_at = @text.length
    region = region(heading_at, heading_at)
    flush.call(@doc.diff { @text.insert(@text.length, "## #{title}\n\n") })
    { title: title, heading: @text.relative_position(heading_at), region: region,
      writer: MarkdownWriter.new(@doc, @text, flush: flush, at: @text.length - 1), named: false }
  end

  # Let one draft out a little, unless a person is where it is writing.
  def draft_step(draft)
    return if draft.done?

    if in_my_way?(draft)
      present_caret("waiting, you're in this section", draft.writer.index,
                    detail: "I'll carry on with #{draft.title} when you leave", sticky: true)
      return
    end
    draft.job.step
    return if draft.done? || !draft.equal?(caret_draft)

    present_caret(working_label, draft.writer.start_index || draft.writer.index, draft.writer.index, sticky: true)
  end

  def caret_draft = drafts.find { |d| !in_my_way?(d) } || drafts.first

  # Someone is on the line being written or the one either side of it.
  # Reading or editing higher up in the section is not in the way.
  def in_my_way?(draft)
    line = MarkdownDoc.line_of_index(text, draft.writer.index)
    occupied_lines.any? { |l| l.between?(line - 1, line + 1) }
  end

  def finish_draft(job)
    draft = drafts.find { |d| d.job.equal?(job) } or return
    drafts.delete(draft)
    forget_thinking(draft.title)
    return draft_failed(draft) if job.failed?

    ensure_trailing_newlines(1) if draft.writer.index >= @text.length
    mark(draft.task, :done, anchor: draft.anchor)
    (@sections ||= []) << { title: draft.title, heading: draft.heading }
    remember_undo("the draft of #{draft.title}", draft.region) if draft.region
    say_drafted(draft)
    @next_scan = 0
  end

  def say_drafted(draft)
    present("drafted #{draft.title}", draft.writer.index,
            detail: "\"#{draft.task.text}\" is done; edit the section and it's yours")
    note_in_review("Drafted #{draft.title} from the list; edit it and it's yours.")
  end

  # Nothing came from the model: the heading or blank lines opened for it go,
  # the task goes back on the list unchecked, and the agent waits a while
  # before picking anything up again.
  def draft_failed(draft)
    discard_region(draft.region)
    mark(draft.task, :open, anchor: draft.anchor)
    report_failure("drafting #{draft.title}", draft.job.error, "the task is back on the list")
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  end

  def handoff(line, request)
    verb, rest = request.sub(/\A@agent\s+/i, "").split(/\s+/, 2)
    delete_line(line)
    case verb.downcase
    when "take"
      add_task(rest.to_s.strip)
      after = drafts.size >= MAX_DRAFTS ? "; I'll start it after #{drafts.map(&:title).join(" and ")}" : ""
      present("took a task", @text.length, detail: "#{rest}#{after}")
      @next_scan = 0
    when "pause"
      @paused = true
      present("paused", @last_index, sticky: true)
    when "resume", "continue"
      @paused = false
      present("back to work", @last_index)
    when "stop"
      stop_task
    end
    @changes.clear
  end

  def stop_task
    return present("nothing to stop", @last_index) unless drafting?

    stopped = drafts.dup
    drafts.clear
    stopped.each do |d|
      d.job.stop
      mark(d.task, :stopped, anchor: d.anchor)
    end
    dropped = stopped.map { |d| "\"#{d.task.text}\"" }.join(" and ")
    present("stopped", @last_index, detail: "dropped #{dropped}; the item is marked [-]")
  end

  def draft_here(line)
    section = MarkdownDoc.section_at(text, line)
    delete_line(line)
    return present("no heading to draft under", @last_index, detail: "put the line under a heading") unless section

    claim(MarkdownDoc::Task.new(line: nil, text: section.title, state: :open, under: section.title, boxed: false))
    @changes.clear
  end
end
