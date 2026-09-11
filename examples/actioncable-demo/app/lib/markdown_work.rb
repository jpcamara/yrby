# frozen_string_literal: true

# MarkdownAgent's own work: tasks from its list in the document, drafted
# where they point (a named section, or a new one at the end), interleaved
# with reacting, yielding while someone is in the section.
module MarkdownWork
  SCAN_EVERY = 3 # seconds between looks at the list while idle

  private

  def work_pending? = !@task.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (@next_scan || 0)

  def work_step
    return if @paused

    @task ? draft_step : pick_task
  rescue StandardError => e
    Rails.logger.warn("agent work failed: #{e.class}: #{e.message}")
    @draft&.stop
    @task = nil
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  end

  def pick_task
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCAN_EVERY
    busy = occupied_lines
    task = tasks.find { |t| t.state == :open && !busy.include?(t.line) }
    return unless task

    present("up next: #{section_title(task.text)}", @last_index, sticky: true,
                                                                 detail: "from your list; say @agent pause to hold me")
    sleep 1.5
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
    @task = task
    @task_anchor = task.line && @text.relative_position(MarkdownDoc.line_start(text, task.line))
    mark(task, :drafting)
    section = open_section(task)
    where = section ? ", under #{section.title}" : ""
    detail = if task.line
               "took \"#{task.text}\" from the list#{where}"
             else
               "drafting the section you pointed at"
             end
    present("drafting #{@section_title}", @draft_writer.index, detail: detail, sticky: true)
    @draft = StreamJob.new(writer: @draft_writer, on_finish: -> { finish_task }) do |emit|
      @reviewer.draft(task.text, text, &emit)
    end
  end

  # The draft goes at the end of the named section when there is one, else
  # into a new section at the end. Returns the section used, or nil.
  def open_section(task)
    section = task.under && MarkdownDoc.section(text, task.under)
    if section
      @section_title = section.title
      @section_heading = @text.relative_position(MarkdownDoc.line_start(text, section.line))
      at = MarkdownDoc.line_end(text, MarkdownDoc.section_content_end(text, section))
      @draft_writer = MarkdownWriter.new(@doc, @text, flush: flush, at: at)
      @draft_writer.feed("\n\n")
    else
      @section_title = section_title(task.text)
      ensure_trailing_newlines(2)
      heading_at = @text.length
      flush.call(@doc.diff { @text.insert(@text.length, "## #{@section_title}\n\n") })
      @section_heading = @text.relative_position(heading_at)
      @draft_writer = MarkdownWriter.new(@doc, @text, flush: flush, at: @text.length)
    end
    section
  end

  # Let the draft out a little, unless a person is in the section.
  def draft_step
    return unless @draft && !@draft.finished?

    if in_my_way?
      present("waiting, you're in this section", @draft_writer.index,
              detail: "I'll carry on with #{@section_title} when you leave", sticky: true)
      return
    end
    @draft.step
    return if @draft.finished?

    present(working_label, @draft_writer.start_index || @draft_writer.index, @draft_writer.index, sticky: true)
  end

  def in_my_way?
    from = @doc.index_at(@section_heading, @text.root_name) or return false
    a = MarkdownDoc.line_of_index(text, from)
    b = MarkdownDoc.line_of_index(text, @draft_writer.index)
    occupied_lines.any? { |l| l.between?(a, b) }
  end

  def finish_task
    ensure_trailing_newlines(1) if @draft_writer.index >= @text.length
    mark(@task, :done, anchor: @task_anchor)
    (@sections ||= []) << { title: @section_title, heading: @section_heading }
    present("drafted #{@section_title}", @draft_writer.index,
            detail: "\"#{@task.text}\" is done; edit the section and it's yours")
    note_in_review("Drafted #{@section_title} from the list; edit it and it's yours.")
    @task = nil
    @next_scan = 0
  end

  def handoff(line, request)
    verb, rest = request.sub(/\A@agent\s+/i, "").split(/\s+/, 2)
    delete_line(line)
    case verb.downcase
    when "take"
      add_task(rest.to_s.strip)
      present("took a task", @text.length, detail: rest)
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
    return present("nothing to stop", @last_index) unless @task

    @draft&.stop
    mark(@task, :stopped, anchor: @task_anchor)
    present("stopped", @last_index, detail: "dropped \"#{@task.text}\"; the item is marked [-]")
    @task = nil
  end

  def draft_here(line)
    section = MarkdownDoc.section_at(text, line)
    delete_line(line)
    return present("no heading to draft under", @last_index, detail: "put the line under a heading") unless section

    claim(MarkdownDoc::Task.new(line: nil, text: section.title, state: :open, under: section.title, boxed: false))
    @changes.clear
  end
end
