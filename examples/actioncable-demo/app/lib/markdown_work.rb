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
    @draft_thread&.kill
    @task = nil
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  end

  def pick_task
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCAN_EVERY
    busy = occupied_lines
    task = tasks.find { |t| t.state == :open && !busy.include?(t.line) }
    claim(task) if task
  end

  def claim(task)
    @task = task
    @held = nil
    @done = false
    @pacer = nil
    @draft = Queue.new
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
    @draft_thread = Thread.new do
      @reviewer.draft(task.text, text) { |chunk| @draft << chunk }
    rescue StandardError => e
      Rails.logger.warn("agent draft failed: #{e.class}: #{e.message}")
    ensure
      @draft << :done
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

  # Take what the model has produced into the pacer, then let a little out.
  # A person in the section holds the pace; the chunks wait in the pacer.
  def draft_step
    @pacer ||= Pacer.new { |piece| @draft_writer.feed(piece) }
    loop do
      chunk = next_chunk
      break unless chunk

      if chunk == :done
        @done = true
        break
      end
      @pacer.feed(chunk)
    end
    return finish_task if @done && !@pacer.pending?
    return unless @pacer.pending?

    if in_my_way?
      present("waiting, you're in this section", @draft_writer.index,
              detail: "I'll carry on with #{@section_title} when you leave", sticky: true)
      return
    end
    @pacer.drain
    present("drafting #{@section_title}", @draft_writer.start_index || @draft_writer.index, @draft_writer.index,
            sticky: true)
  end

  def next_chunk
    @draft.pop(true)
  rescue ThreadError
    nil
  end

  def in_my_way?
    from = @doc.index_at(@section_heading, @text.root_name) or return false
    a = MarkdownDoc.line_of_index(text, from)
    b = MarkdownDoc.line_of_index(text, @draft_writer.index)
    occupied_lines.any? { |l| l.between?(a, b) }
  end

  def finish_task
    @pacer&.flush
    @draft_writer.finish
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

    @draft_thread&.kill
    @pacer&.flush
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
