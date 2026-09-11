# frozen_string_literal: true

# The agent's backlog lives in the document: a bulleted list whose items start
# with a text checkbox. "[ ]" is open, "[~]" is being drafted, "[x]" is done,
# "[-]" was stopped. A list is the agent's when the block above it names the
# agent (a heading like "For the agent") or an item mentions @agent. Lexxy has
# no checkbox nodes, so plain text does the job in any editor.
module Worklist
  module_function

  Task = Data.define(:list, :index, :text, :state)

  BOX = /\A\[([ ~xX-])\]\s*(.+)\z/m
  STATES = { " " => :open, "~" => :drafting, "x" => :done, "X" => :done, "-" => :stopped }.freeze

  def tasks(doc)
    root = doc.get_xml_text("root")
    (0...root.xml_text_count).flat_map do |i|
      list = root.xml_text(i)
      next [] if list.xml_text_count.zero?

      mine = i.positive? && root.xml_text(i - 1).text.match?(/\bagent\b/i)
      (0...list.xml_text_count).filter_map do |j|
        m = list.xml_text(j).text.strip.match(BOX) or next
        next unless mine || m[2].match?(/@agent/i)

        Task.new(list: list.anchor, index: j, text: title(m[2]), state: STATES[m[1]])
      end
    end
  end

  def title(text) = text.sub(/@agent\s*/i, "").strip

  # Rewrite an item's checkbox. The item is found through its list's anchor,
  # and only if it still reads as this task. Returns the update, or nil.
  def mark(doc, task, state)
    box = STATES.key(state) or raise ArgumentError, state.to_s
    list = doc.find(task.list) or return
    return if task.index >= list.xml_text_count

    item = list.xml_text(task.index)
    text = item.text
    m = text.match(BOX) or return
    return unless title(m[2]) == task.text

    at = text.index("[")
    doc.diff do
      item.delete(at + 1, 3)
      item.insert(at + 1, "[#{box}]")
    end
  end

  # Add an open task to the agent's list, creating the heading and list at the
  # end of the document if there is none yet.
  def add(doc, text)
    root = doc.get_xml_text("root")
    doc.diff do
      list = agent_list(root)
      unless list
        Y::Lexical.append_heading(doc, "For the agent", tag: "h2")
        list = Y::Lexxy.append_list(doc, [])
      end
      item = list.push_xml_text(Y::Lexxy.list_item_attributes(list.xml_text_count + 1))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
      item.insert(1, "[ ] #{text}")
    end
  end

  def agent_list(root)
    (1...root.xml_text_count).each do |i|
      list = root.xml_text(i)
      return list if list.xml_text_count.positive? && root.xml_text(i - 1).text.match?(/\bagent\b/i)
    end
    nil
  end

  # Ordinals of the agent's lists and the headings above them.
  def ordinals(doc)
    tasks(doc).filter_map { |t| doc.block_at(t.list) }.uniq.flat_map { |i| [i - 1, i] }.reject(&:negative?)
  end
end
