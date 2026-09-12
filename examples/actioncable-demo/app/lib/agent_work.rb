# frozen_string_literal: true

# The agent's own work, done alongside people rather than in reply to them.
# It takes open tasks from its list in the document, drafts a section for each
# (at the end of the document, or under the heading the task names), and
# checks the item off. Like a person, it writes in one place at a time: the
# review first, then one task after another (AGENT_DRAFTS raises that; the
# streams then share one caret). The model streams in a thread while the
# watch loop lets a little out per turn and keeps reacting in between. A
# draft yields while someone is at the point it is writing. A section it drafted belongs to whoever edits it next: their
# change goes into memory, and the agent does not edit that section again on
# its own.
module AgentWork
  SCAN_EVERY = 3 # seconds between looks at the list while idle
  MAX_DRAFTS = ENV.fetch("AGENT_DRAFTS", "1").to_i
  LISTENING = "I'll look at changes once a sentence is finished, answer @agent lines, and take tasks you add"

  # One section being drafted: the task it came from, the writer streaming
  # into the document, the section's heading and title, whether the agent
  # added that heading, the block the caret sat at before the first words,
  # and the model stream.
  Draft = Data.define(:task, :writer, :heading, :title, :made_heading, :at, :job) do
    def done? = job.finished?
  end

  private

  def drafts = (@drafts ||= [])

  def drafting? = drafts.any?

  def work_pending? = drafting? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (@next_scan || 0)

  # One step of the agent's own work. Whatever goes wrong here is logged and
  # the drafts dropped; the agent stays in the document.
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
      Worklist.mark(doc, d.task, :open)&.then { |u| flush.call(u) }
      report_failure("drafting #{d.title}", error, "the task is back on the list")
    end
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  end

  def pick_task
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCAN_EVERY
    occupied = occupied_blocks
    task = tasks_for_me.find { |t| t.state == :open && !occupied.include?(doc.block_at(t.list)) }
    return unless task

    at = end_of(last_block)
    unless @last_presence&.dig(:status) == "up next: #{section_title(task.text)}" # announce_next may have said so
      present("up next: #{section_title(task.text)}", at, at, sticky: true,
                                                              detail: "from your list; say @agent pause to hold me")
    end
    sleep 1.5 unless drafting? # a pause to read it, unless a draft is waiting on this loop
    claim(task)
  end

  def tasks_for_me = Worklist.tasks(doc, except: ["Agent review"])

  # After the review, say what comes next.
  def announce_next
    return present(working_label, end_of(last_block), end_of(last_block), sticky: true) if drafting?

    task = tasks_for_me.find { |t| t.state == :open }
    if task
      present("up next: #{section_title(task.text)}", end_of(last_block), end_of(last_block), detail: "from your list")
    else
      present("listening", end_of(last_block), end_of(last_block), sticky: true, detail: LISTENING)
    end
  end

  # Mark the item, open the section, and start the model streaming.
  def claim(task)
    Worklist.mark(doc, task, :drafting)&.then { |u| flush.call(u) }
    section = open_section(task)
    title = section[:title]
    where = task.under && title != section_title(task.text) ? ", under #{title}" : ""
    detail = task.list ? "took \"#{task.text}\" from the list#{where}" : "drafting the section you pointed at"
    present("drafting #{title}", end_of(section[:at]), end_of(section[:at]), sticky: true, detail: detail)
    start_draft(task, section)
  end

  def start_draft(task, section)
    job = nil
    job = StreamJob.new(writer: section[:writer], label: section[:title], on_finish: -> { finish_draft(job) }) do |emit|
      @reviewer.draft(task.text, text, &emit)
    end
    drafts << Draft.new(task: task, writer: section[:writer], heading: section[:heading], title: section[:title],
                        made_heading: section[:made_heading], at: section[:at].anchor, job: job)
  end

  # The draft goes at the end of the named section when there is one, else
  # into a new section at the end of the document. `at` is the block the
  # caret sits at while the first words arrive.
  def open_section(task)
    heading = task.under && heading_block(task.under)
    heading ? open_under(heading) : open_new_section(section_title(task.text))
  end

  def open_under(heading)
    last = root.xml_text(section_end(doc.block_at(heading.anchor)))
    { heading: heading.anchor, title: heading.text.strip, made_heading: false, at: last,
      writer: StreamingWriter.new(doc, flush: flush, after: last.anchor) }
  end

  def open_new_section(title)
    flush.call(doc.diff { Y::Lexical.append_heading(doc, title, tag: "h2") })
    { heading: last_block.anchor, title: title, made_heading: true, at: last_block,
      writer: StreamingWriter.new(doc, flush: flush, after: last_block.anchor) }
  end

  # The first heading whose text matches, exactly then loosely.
  def heading_block(text)
    headings = (0...root.xml_text_count).map { |i| root.xml_text(i) }.select { |b| b.attributes["__type"] == "heading" }
    headings.find { |b| b.text.strip.casecmp?(text.strip) } ||
      headings.find { |b| b.text.strip.downcase.include?(text.strip.downcase) }
  end

  # Ordinal of the last block of the section that starts at heading `h`.
  def section_end(heading)
    nxt = ((heading + 1)...root.xml_text_count).find { |i| root.xml_text(i).attributes["__type"] == "heading" }
    (nxt || root.xml_text_count) - 1
  end

  # "@agent draft this section": the heading meant by "this" (selected, or
  # just above the line) gets its section drafted in place.
  def draft_here(index)
    scope = selection_for(index)
    from, to = take_request(index, scope)
    return present("no section to draft", nil, nil) unless from

    h = (from..to).find { |i| root.xml_text(i).attributes["__type"] == "heading" } ||
        from.downto(0).find { |i| root.xml_text(i).attributes["__type"] == "heading" }
    unless h
      return present("no heading to draft under", nil, nil,
                     detail: "put the line under a heading, or select one")
    end

    title = root.xml_text(h).text.strip
    claim(Worklist::Task.new(list: nil, index: nil, text: title, state: :open, under: title))
    @changes.clear
  end

  # "Draft the rollback plan" becomes a section called "Rollback plan".
  def section_title(text)
    title = text.sub(/\A(draft|write|add|create|outline|prepare)\s+(the\s+|a\s+|an\s+)?/i, "").strip
    title = text if title.empty?
    title[0].upcase + title[1..].to_s
  end

  # Let one draft out a little, unless a person is where it is writing. The
  # caret follows the first draft that is moving.
  def draft_step(draft)
    return if draft.done?

    if in_my_way?(draft)
      at = draft.writer.block || doc.find(draft.heading) || last_block
      present_caret("waiting, you're in this section", end_of(at), end_of(at),
                    detail: "I'll carry on with #{draft.title} when you leave", sticky: true)
      return
    end
    draft.job.step
    return unless draft.writer.block && !draft.done? && draft.equal?(caret_draft)

    present_caret(working_label, start_of_written(draft.writer) || end_of(draft.writer.block),
                  end_of(draft.writer.block), sticky: true)
  end

  def caret_draft = drafts.find { |d| !in_my_way?(d) } || drafts.first

  # Someone is at the point being written: the block the words go into, or
  # the one right after it. Reading or editing higher up in the section is
  # not in the way; new text lands below them.
  def in_my_way?(draft)
    point = draft.writer.block ? doc.block_at(draft.writer.block.anchor) : doc.block_at(draft.at)
    return false unless point

    occupied_blocks.intersect?([point, point + 1])
  end

  def finish_draft(job)
    draft = drafts.find { |d| d.job.equal?(job) } or return
    drafts.delete(draft)
    forget_thinking(draft.title)
    return draft_failed(draft) if job.failed?

    Worklist.mark(doc, draft.task, :done)&.then { |u| flush.call(u) }
    (@sections ||= []) << { title: draft.task.text, heading: draft.heading, blocks: draft.writer.created }
    say_drafted(draft)
    @next_scan = 0
  end

  def say_drafted(draft)
    at = draft.writer.block || last_block
    present("drafted #{draft.title}", end_of(at), end_of(at),
            detail: "\"#{draft.task.text}\" is done; edit the section and it's yours")
    note_in_review("Drafted #{draft.title} from the list; edit it and it's yours.")
  end

  # Take out whatever was opened for a draft that never came: the blocks the
  # writer made, and the heading when the agent added it.
  def discard_draft(draft)
    anchors = draft.writer.created.reverse
    anchors << draft.heading if draft.made_heading
    flush.call(doc.diff do
      anchors.each { |a| (i = doc.block_at(a)) && root.delete_xml_text(i) }
    end)
  end

  # Nothing came from the model: the task goes back on the list, unchecked,
  # and the agent waits a while before picking anything up again.
  def draft_failed(draft)
    discard_draft(draft)
    Worklist.mark(doc, draft.task, :open)&.then { |u| flush.call(u) }
    report_failure("drafting #{draft.title}", draft.job.error, "the task is back on the list")
    @next_scan = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  end

  # "@agent take <task>", "@agent pause", "@agent resume", "@agent stop".
  def handoff(index, line)
    verb, rest = line.sub(/\A@agent\s+/i, "").split(/\s+/, 2)
    flush.call(doc.diff { root.delete_xml_text(index) })
    case verb.downcase
    when "take"
      flush.call(Worklist.add(doc, rest.to_s.strip))
      after = drafts.size >= MAX_DRAFTS ? "; I'll start it after #{drafts.map(&:title).join(" and ")}" : ""
      present("took a task", end_of(last_block), end_of(last_block), detail: "#{rest}#{after}")
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
    return present("nothing to stop", nil, nil) unless drafting?

    stopped = drafts.dup
    drafts.clear
    stopped.each do |d|
      d.job.stop
      Worklist.mark(doc, d.task, :stopped)&.then { |u| flush.call(u) }
    end
    dropped = stopped.map { |d| "\"#{d.task.text}\"" }.join(" and ")
    present("stopped", nil, nil, detail: "dropped #{dropped}; the item is marked [-]")
  end

  # The title of the drafted section a block belongs to, if any.
  def my_section(ordinal)
    Array(@sections).find do |s|
      [s[:heading], *s[:blocks]].any? { |a| doc.block_at(a) == ordinal }
    end&.fetch(:title)
  end

  # Blocks the agent's reactions must leave alone: its task lists and their
  # headings, the sections it is drafting now, and the sections it drafted.
  def my_blocks
    current = drafts.flat_map { |d| [d.heading, *d.writer.created] }
    done = Array(@sections).flat_map { |s| [s[:heading], *s[:blocks]] }
    (Worklist.ordinals(doc) + (current + done).filter_map { |a| doc.block_at(a) }).uniq.sort
  end
end
