# frozen_string_literal: true

# The small edits MarkdownAgent makes to the text around its work: marking a
# task line, adding a task, removing a request line, a why-line under its
# review, trailing newlines before it appends.
module MarkdownEdits
  private

  # Tasks in the document, never counting the agent's own review section.
  def tasks = MarkdownDoc.tasks(text, except: [MarkdownAgent::REVIEW_TITLE])

  # Mark the task's line. The line is found again through the anchor made
  # when the task was claimed (a draft landing above the list moves the line),
  # and only marked if it still reads as this task.
  def mark(task, state, anchor: nil)
    return unless task.line

    line = anchor ? line_of_anchor(anchor) : task.line
    ls = MarkdownDoc.lines(text)
    current = line && ls[line] or return
    return unless tasks.any? { |t| t.line == line && t.text == task.text }

    replacement = MarkdownDoc.marked(current, state)
    from = MarkdownDoc.line_start(text, line)
    flush.call(@doc.diff do
      @text.delete(from, current.bytesize)
      @text.insert(from, replacement)
    end)
  end

  def line_of_anchor(anchor)
    i = @doc.index_at(anchor, @text.root_name) or return
    MarkdownDoc.line_of_index(text, i)
  end

  def add_task(title)
    section = MarkdownDoc.sections(text).find { |s| s.title.match?(/\bagent\b/i) }
    if section
      at = MarkdownDoc.line_end(text, MarkdownDoc.section_content_end(text, section))
      flush.call(@doc.diff { @text.insert(at, "\n- [ ] #{title}") })
    else
      ensure_trailing_newlines(2)
      flush.call(@doc.diff { @text.insert(@text.length, "## For the agent\n\n- [ ] #{title}\n") })
    end
  end

  def delete_line(line)
    from = MarkdownDoc.line_start(text, line)
    len = MarkdownDoc.lines(text)[line].to_s.bytesize
    len += 1 if from + len < @text.length # take the newline too
    flush.call(@doc.diff { @text.delete(from, len) })
  end

  # A short line in the review section on each thing it did and why.
  def note_in_review(line)
    at = review_line or return
    section = MarkdownDoc.section_at(text, at) or return
    pos = MarkdownDoc.line_end(text, MarkdownDoc.section_content_end(text, section))
    flush.call(@doc.diff { @text.insert(pos, "\n- #{line.to_s.gsub(/\s+/, " ").strip[0, 200]}") })
  end

  def ensure_trailing_newlines(count)
    current = text[/\n*\z/].length
    return if current >= count

    flush.call(@doc.diff { @text.insert(@text.length, "\n" * (count - current)) })
  end

  def section_title(task_text)
    title = task_text.sub(/\A(draft|write|add|create|outline|prepare)\s+(the\s+|a\s+|an\s+)?/i, "").strip
    title = task_text if title.empty?
    title[0].upcase + title[1..].to_s
  end
end
