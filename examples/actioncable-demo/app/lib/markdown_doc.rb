# frozen_string_literal: true

# Reading a markdown document as text: lines and their character offsets,
# headings and the sections under them, paragraphs (blank-line separated),
# and the agent's task lines. Everything is computed from the string each
# time, which is cheap at document size and never stale.
module MarkdownDoc
  module_function

  Section = Data.define(:title, :level, :line, :last_line)
  Paragraph = Data.define(:index, :first_line, :last_line, :text)
  Task = Data.define(:line, :text, :state, :under, :boxed)

  BOX = /\A(\s*[-*]\s+)\[([ ~xX-])\]\s*(.+)\z/
  BULLET = /\A(\s*[-*]\s+)(.+)\z/
  HEADING = /\A(\#{1,6})\s+(.+?)\s*#*\s*\z/
  UNDER = /\A(.+?)\s+under\s+["“]?([^"”]+?)["”]?\s*\z/i
  STATES = { " " => :open, "~" => :drafting, "x" => :done, "X" => :done, "-" => :stopped }.freeze

  def lines(text) = text.split("\n", -1)

  # Offsets are in bytes: that is the index space `Y::Text` exposes from
  # Ruby, so a byte offset from the string is the index to insert at.
  def line_start(text, index)
    lines(text).first(index).sum { |l| l.bytesize + 1 }
  end

  def line_end(text, index) = line_start(text, index) + lines(text)[index].to_s.bytesize

  # The line a byte index falls on.
  def line_of_index(text, index) = text.byteslice(0, index).to_s.count("\n")

  def sections(text)
    ls = lines(text)
    heads = ls.each_with_index.filter_map { |l, i| (m = l.match(HEADING)) && [i, m[1].length, m[2]] }
    heads.each_with_index.map do |(line, level, title), k|
      nxt = heads[(k + 1)..].find { |(_, lvl, _)| lvl <= level }
      Section.new(title: title, level: level, line: line, last_line: (nxt ? nxt[0] : ls.length) - 1)
    end
  end

  def section(text, title)
    all = sections(text)
    all.find { |s| s.title.casecmp?(title.strip) } || all.find { |s| s.title.downcase.include?(title.strip.downcase) }
  end

  # The last line of a section that has text on it, so an insertion at the
  # section's end lands before the blank line that precedes the next heading.
  def section_content_end(text, section)
    ls = lines(text)
    line = section.last_line
    line -= 1 while line > section.line && ls[line].to_s.strip.empty?
    line
  end

  # The section a line belongs to, or nil above the first heading.
  def section_at(text, line)
    sections(text).select { |s| s.line <= line }.max_by(&:line)
  end

  def paragraphs(text)
    ls = lines(text)
    out = []
    start = nil
    ls.each_with_index do |l, i|
      if l.strip.empty?
        out << [start, i - 1] if start
        start = nil
      else
        start ||= i
      end
    end
    out << [start, ls.length - 1] if start
    out.each_with_index.map do |(a, b), k|
      Paragraph.new(index: k, first_line: a, last_line: b, text: ls[a..b].join("\n"))
    end
  end

  # Tasks: box lines anywhere that mention @agent, and every bullet under a
  # heading that names the agent, boxed or not.
  def tasks(text, except: [])
    ls = lines(text)
    mine = false
    ls.each_with_index.filter_map do |l, i|
      if (h = l.match(HEADING))
        mine = h[2].match?(/\bagent\b/i) && except.none? { |x| h[2].strip.casecmp?(x) }
        next
      end
      if (m = l.match(BOX))
        next unless mine || m[3].match?(/@agent/i)

        build(i, m[3], STATES[m[2]], true)
      elsif mine && (m = l.match(BULLET))
        build(i, m[2], :open, false)
      end
    end
  end

  def build(line, body, state, boxed)
    body = body.sub(/@agent\s*/i, "").strip
    text, under = body.match(UNDER)&.captures || [body, nil]
    Task.new(line: line, text: text.strip, state: state, under: under&.strip, boxed: boxed)
  end

  # The line's text with its box set to `state`, adding a box if it had none.
  def marked(line_text, state)
    box = STATES.key(state)
    if (m = line_text.match(BOX))
      "#{m[1]}[#{box}] #{m[3]}"
    elsif (m = line_text.match(BULLET))
      "#{m[1]}[#{box}] #{m[2]}"
    else
      line_text
    end
  end

  def agent_line?(line_text) = line_text.strip.match?(/\A@agent\b/i)
end
