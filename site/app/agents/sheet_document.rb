# The agent sheet's document as SheetAgent reads and writes it.
# app/agents/sheet_agent.rb documents its shape. Writes go inside the agent's
# `edit`.
class SheetDocument
  CELL_FIELDS = %w[input format bold fill color by ask].freeze
  MAX_LISTING = 600 # cells the model sees

  def initialize(doc)
    @doc = doc
  end

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def tab_ids = @doc.get_array("tabs").to_a.uniq.select { |id| tab(id) }
  def tab_name(id) = tab(id)&.[]("name")
  def tab_named(name) = tab_ids.find { |id| tab_name(id).to_s.casecmp?(name) }

  # The sheet as the model reads it: each tab's name, then its non-empty
  # cells as "B4: input", row by row.
  def listing
    remaining = MAX_LISTING
    tab_ids.map do |id|
      cells = inputs(id).first(remaining)
      remaining -= cells.size
      body = cells.empty? ? "(empty)" : cells.map { |ref, input| "#{ref}: #{input}" }.join("\n")
      %(Tab "#{tab_name(id)}":\n#{body})
    end.join("\n\n")
  end

  # Writes `write` (a SheetWrites::Write) to `tab`, marked with the ask and
  # who wrote it. The ask keeps the cell as it was before the ask's first
  # write to it, so Undo goes back to before the ask, however many times the
  # ask wrote the cell.
  def write(ask_id, tab, write, by:)
    cells = child_map(tab(tab), "cells")
    remember(ask_id, "#{tab}!#{write.cell}", cells.get_map(write.cell))
    fields = { "input" => write.input, "format" => write.format, "bold" => write.bold, "fill" => write.fill,
               "by" => by, "ask" => ask_id }.compact
    if (cell = cells.get_map(write.cell))
      fields.each { |key, value| cell[key] = value }
    else
      cells[write.cell] = fields
    end
  end

  # Sets an ask's fields. A nil value deletes the field.
  def update(id, fields)
    ask = ask(id) or return
    fields.each { |key, value| value.nil? ? ask.delete(key) : ask[key] = value }
  end

  private

  def tab(id) = @doc.get_map("sheets").get_map(id)

  # A tab's non-empty inputs as [ref, input], row by row.
  def inputs(id)
    cells = tab(id).get_map("cells").to_h # nil.to_h is {}
    found = cells.filter_map do |ref, cell|
      input = cell.is_a?(Hash) ? cell["input"].to_s.tr("\n", " ") : ""
      [ref, input] if !input.empty? && SheetWrites::CELL.match?(ref)
    end
    found.sort_by { |ref, _| position(ref) }
  end

  # Row, then column, so "B4" sorts before "AA10".
  def position(ref)
    m = SheetWrites::CELL.match(ref)
    [m[2].to_i, m[1].each_char.reduce(0) { |n, ch| (n * 26) + ch.ord - 64 }]
  end

  def remember(ask_id, key, cell)
    ask = ask(ask_id) or return
    before = child_map(ask, "before")
    before[key] = cell ? cell.to_h.slice(*CELL_FIELDS) : {} unless before.key?(key)
  end

  # The Y::Map at `key` in `parent`, created empty when it isn't there.
  def child_map(parent, key)
    parent.get_map(key) || begin
      parent[key] = {}
      parent.get_map(key)
    end
  end
end
