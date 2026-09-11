# frozen_string_literal: true

# The agent's backlog lives in the document: a bulleted list whose items start
# with a text checkbox. "[ ]" is open, "[~]" is being drafted, "[x]" is done,
# "[-]" was stopped. A list is the agent's when the block above it names the
# agent (a heading like "For the agent") or an item mentions @agent. Lexxy has
# no checkbox nodes, so plain text does the job in any editor.
module Worklist
  module_function

  Task = Data.define(:list, :index, :text, :state, :under)

  BOX = /\A\[([ ~xX-])\]\s*(.+)\z/m
  UNDER = /\A(.+?)\s+under\s+["“]?([^"”]+?)["”]?\s*\z/i
  STATES = { " " => :open, "~" => :drafting, "x" => :done, "X" => :done, "-" => :stopped }.freeze

  # Tasks are list items, or plain paragraphs that start with a box (easier
  # to type in an editor with no list shortcut). A block that names the agent
  # starts a group: the list or the run of box paragraphs right after it is
  # the agent's, and items in that list need no box, since a pasted markdown
  # task list loses its boxes in Lexxy. An item that mentions @agent is the
  # agent's anywhere. "<task> under <Heading>" places the draft in that
  # section. A paragraph task has no index.
  # Only a heading names the agent's group, and never one in `except:`
  # (the agent's own review), so a paragraph that mentions the agent, or the
  # agent's own suggestions, do not turn into tasks.
  def tasks(doc, except: [])
    root = doc.get_xml_text("root")
    mine = false
    (0...root.xml_text_count).flat_map do |i|
      block = root.xml_text(i)
      if block.xml_text_count.positive?
        found = list_tasks(block, mine)
        mine = false
        found
      elsif (m = block.text.strip.match(BOX))
        next [] unless mine || m[2].match?(/@agent/i)

        [build(block.anchor, nil, m[2], STATES[m[1]])]
      else
        title = block.text.strip
        mine = block.attributes["__type"] == "heading" && title.match?(/\bagent\b/i) &&
               except.none? { |x| title.casecmp?(x) }
        []
      end
    end
  end

  def list_tasks(list, mine)
    (0...list.xml_text_count).filter_map do |j|
      text = list.xml_text(j).text.strip
      if (m = text.match(BOX))
        build(list.anchor, j, m[2], STATES[m[1]]) if mine || m[2].match?(/@agent/i)
      elsif !text.empty? && (mine || text.match?(/@agent/i))
        build(list.anchor, j, text, :open)
      end
    end
  end

  def build(list, index, body, state)
    body = body.sub(/@agent\s*/i, "").strip
    text, under = body.match(UNDER)&.captures || [body, nil]
    Task.new(list: list, index: index, text: text.strip, state: state, under: under&.strip)
  end

  def title(text)
    body = text.sub(/@agent\s*/i, "").strip
    (body.match(UNDER)&.captures&.first || body).strip
  end

  # Rewrite an item's checkbox, adding one if the item has none. The item is
  # found through its list's anchor, and only if it still reads as this
  # task. Returns the update, or nil.
  def mark(doc, task, state)
    box = STATES.key(state) or raise ArgumentError, state.to_s
    list = task.list && doc.find(task.list) or return
    return if task.index && task.index >= list.xml_text_count

    item = task.index ? list.xml_text(task.index) : list
    text = item.text
    m = text.match(BOX)
    return unless title(m ? m[2] : text) == task.text

    offset = item.length - text.length # the text node marker sits before the text
    doc.diff do
      if m
        at = offset + text.index("[")
        item.delete(at, 3)
        item.insert(at, "[#{box}]")
      else
        item.insert(offset, "[#{box}] ")
      end
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
      above = root.xml_text(i - 1)
      next unless list.xml_text_count.positive? && above.attributes["__type"] == "heading"
      return list if above.text.match?(/\bagent\b/i) && !above.text.strip.casecmp?("Agent review")
    end
    nil
  end

  # Ordinals of the agent's task blocks and of the blocks that name it right
  # above them.
  def ordinals(doc)
    root = doc.get_xml_text("root")
    tasks(doc, except: ["Agent review"]).filter_map { |t| doc.block_at(t.list) }.uniq.flat_map do |i|
      above = i.positive? && root.xml_text(i - 1)
      above && above.attributes["__type"] == "heading" && above.text.match?(/\bagent\b/i) ? [i - 1, i] : [i]
    end.uniq
  end
end
