# frozen_string_literal: true

# The agent's own work, done alongside people rather than in reply to them.
# It takes open tasks from its list in the document, drafts a section for each
# at the end of the document, and checks the item off. Drafting is interleaved
# with reacting: the model streams in a thread, and the watch loop writes a
# few chunks whenever no edit is waiting. If someone steps into the block it
# is writing, it holds the next chunk until they leave. A section it drafted
# belongs to whoever edits it next: their change goes into memory, and the
# agent does not edit that section again on its own.
module AgentWork
  SCAN_EVERY = 3 # seconds between looks at the list while idle

  private

  def work_pending? = !@task.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (@next_scan || 0)

  # One step of the agent's own work. Whatever goes wrong here is logged and
  # the task dropped; the agent stays in the document.
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
    occupied = occupied_blocks
    task = Worklist.tasks(doc).find { |t| t.state == :open && !occupied.include?(doc.block_at(t.list)) }
    claim(task) if task
  end

  # Mark the item, open a section at the end, and start the model streaming.
  def claim(task)
    @task = task
    @held = nil
    @draft = Queue.new
    Worklist.mark(doc, task, :drafting)&.then { |u| flush.call(u) }
    flush.call(doc.diff { Y::Lexical.append_heading(doc, section_title(task.text), tag: "h2") })
    @section_heading = last_block.anchor
    @draft_writer = StreamingWriter.new(doc, flush: flush)
    present("drafting #{section_title(task.text)}", end_of(last_block), end_of(last_block),
            detail: "took \"#{task.text}\" from the list", sticky: true)
    start_draft(task)
  end

  # "Draft the rollback plan" becomes a section called "Rollback plan".
  def section_title(text)
    title = text.sub(/\A(draft|write|add|create|outline|prepare)\s+(the\s+|a\s+|an\s+)?/i, "").strip
    title = text if title.empty?
    title[0].upcase + title[1..].to_s
  end

  def start_draft(task)
    @draft_thread = Thread.new do
      @reviewer.draft(task.text, text) { |chunk| @draft << chunk }
    rescue StandardError => e
      Rails.logger.warn("agent draft failed: #{e.class}: #{e.message}")
    ensure
      @draft << :done
    end
  end

  # Write what has streamed in so far, a few chunks per step, yielding the
  # block to a person who is in it.
  def draft_step
    8.times do
      chunk = @held || next_chunk
      return unless chunk
      return finish_task if chunk == :done

      if in_my_way?
        @held = chunk
        present("waiting, you're in this section", end_of(@draft_writer.block), end_of(@draft_writer.block),
                detail: "I'll carry on with #{section_title(@task.text)} when you leave", sticky: true)
        return
      end
      @held = nil
      @draft_writer.feed(chunk)
      if @draft_writer.block
        present("drafting #{section_title(@task.text)}", end_of(@draft_writer.block), end_of(@draft_writer.block),
                sticky: true)
      end
    end
  end

  def next_chunk
    @draft.pop(true)
  rescue ThreadError
    nil
  end

  # Someone is in the section being drafted: its heading or any block written so far.
  def in_my_way?
    section = [@section_heading, *@draft_writer.created].filter_map { |a| doc.block_at(a) }
    occupied_blocks.intersect?(section)
  end

  def finish_task
    @draft_writer.finish
    Worklist.mark(doc, @task, :done)&.then { |u| flush.call(u) }
    (@sections ||= []) << { title: @task.text, heading: @section_heading, blocks: @draft_writer.created }
    at = @draft_writer.block || last_block
    present("drafted #{section_title(@task.text)}", end_of(at), end_of(at),
            detail: "\"#{@task.text}\" is done; edit the section and it's yours")
    @task = nil
    @next_scan = 0
  end

  # "@agent take <task>", "@agent pause", "@agent resume", "@agent stop".
  def handoff(index, line)
    verb, rest = line.sub(/\A@agent\s+/i, "").split(/\s+/, 2)
    flush.call(doc.diff { root.delete_xml_text(index) })
    case verb.downcase
    when "take"
      flush.call(Worklist.add(doc, rest.to_s.strip))
      present("took a task", end_of(last_block), end_of(last_block), detail: rest)
      @next_scan = 0
    when "pause"
      @paused = true
      present("paused", nil, nil, sticky: true)
    when "resume", "continue"
      @paused = false
      present("back to work", nil, nil)
    when "stop"
      stop_task
    end
    @changes.clear
  end

  def stop_task
    return present("nothing to stop", nil, nil) unless @task

    @draft_thread&.kill
    @draft_writer&.finish
    Worklist.mark(doc, @task, :stopped)&.then { |u| flush.call(u) }
    present("stopped", nil, nil, detail: "dropped \"#{@task.text}\"; the item is marked [-]")
    @task = nil
  end

  # The title of the drafted section a block belongs to, if any.
  def my_section(ordinal)
    Array(@sections).find do |s|
      [s[:heading], *s[:blocks]].any? { |a| doc.block_at(a) == ordinal }
    end&.fetch(:title)
  end

  # Blocks the agent's reactions must leave alone: its task lists and their
  # headings, the section it is drafting now, and the sections it drafted.
  def my_blocks
    current = @task ? [@section_heading, *@draft_writer.created] : []
    done = Array(@sections).flat_map { |s| [s[:heading], *s[:blocks]] }
    (Worklist.ordinals(doc) + (current + done).filter_map { |a| doc.block_at(a) }).uniq.sort
  end
end
