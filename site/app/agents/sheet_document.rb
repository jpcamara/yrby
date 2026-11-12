require "securerandom"

# The agent sheet's document as SheetAgent reads and writes it.
# app/agents/sheet_agent.rb documents its shape. Writes go inside the agent's
# `edit`.
class SheetDocument
  CELL_FIELDS = %w[input format bold fill color by ask].freeze
  SHOWN = %w[input format bold fill color].freeze # a cell with none of these is gone
  MAX_LISTING = 600 # cells the model reads in one look

  def initialize(doc)
    @doc = doc
  end

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def tab_ids = @doc.get_array("tabs").to_a.uniq.select { |id| tab(id) }
  def tab_names = tab_ids.map { |id| tab_name(id) }
  def tab_name(id) = tab(id)&.[]("name")
  def tab_named(name) = tab_ids.find { |id| tab_name(id).to_s.casecmp?(name.to_s.strip) }

  # One line per tab: its name and the range it uses, for the model's prompt.
  def overview
    tab_ids.map do |id|
      refs = filled(id).keys
      used = refs.empty? ? "empty" : "#{SheetSpec.bounds(refs)}, #{refs.size} cells"
      %(- "#{tab_name(id)}": #{used})
    end.join("\n")
  end

  # A tab's cells as the model reads them, row by row, or only those in
  # `range` ("A1:G9"). Cells the ask `mine` wrote say "yours".
  def listing(id, range: nil, mine: nil)
    cells = within(id, range)
    lines = cells.sort_by { |ref, _| SheetSpec.ref(ref).reverse }.first(MAX_LISTING).map do |ref, cell|
      SheetSpec.describe(ref, cell, mine: mine && cell["ask"] == mine)
    end
    name = %(Tab "#{tab_name(id)}"#{" #{range}" if range})
    head = cells.empty? ? "#{name} is empty." : "#{name}:"
    more = cells.size > MAX_LISTING ? ["(#{cells.size - MAX_LISTING} more cells not listed)"] : []
    [head, *lines, *more].join("\n")
  end

  # The cell as a Hash of its fields, or nil.
  def cell(id, ref) = tab(id)&.get_map("cells").to_h[ref]&.slice(*CELL_FIELDS)

  # Sets fields on a cell; a nil value removes the field. A cell left with
  # nothing to show goes.
  def set_cell(id, ref, fields)
    cells = child_map(tab(id), "cells")
    cell = child_map(cells, ref)
    fields.each { |key, value| value.nil? ? cell.delete(key) : cell[key] = value }
    cells.delete(ref) unless cell.to_h.keys.intersect?(SHOWN)
  end

  def clear_cell(id, ref) = tab(id)&.get_map("cells")&.delete(ref)

  def width(id, column) = tab(id)&.get_map("widths")&.[](column)

  def set_width(id, column, pixels)
    widths = child_map(tab(id), "widths")
    pixels ? widths[column] = pixels : widths.delete(column)
  end

  # Adds an empty tab at the end and returns its id.
  def add_tab(name)
    id = SecureRandom.alphanumeric(8)
    @doc.get_map("sheets")[id] = { "name" => name, "cells" => {}, "widths" => {} }
    @doc.get_array("tabs").push(id)
    id
  end

  # Renames a tab and rewrites every formula that names it, so they follow,
  # as the page does. Yields each tab and cell it rewrites.
  def rename_tab(id, to)
    from = tab_name(id)
    tab(id)["name"] = to
    tab_ids.each do |each_tab|
      tab(each_tab).get_map("cells")&.to_h&.each do |ref, cell|
        after = SheetSpec.rename(cell["input"], from, to)
        next if after == cell["input"]

        tab(each_tab).get_map("cells").get_map(ref)["input"] = after
        yield each_tab, ref if block_given?
      end
    end
  end

  # Sets an ask's fields. A nil value deletes the field.
  def update(id, fields)
    ask = ask(id) or return
    fields.each { |key, value| value.nil? ? ask.delete(key) : ask[key] = value }
  end

  # The Y::Map at `key` in `parent`, created empty when it isn't there.
  def child_map(parent, key)
    parent.get_map(key) || begin
      parent[key] = {}
      parent.get_map(key)
    end
  end

  private

  def tab(id) = id && @doc.get_map("sheets").get_map(id)

  # A tab's cells that show something, in `range` when given.
  def within(id, range)
    bounds = range && SheetSpec.range(range)
    filled(id).select { |ref, _| !bounds || SheetSpec.covers?(bounds, ref) }
  end

  # A tab's cells that show something, as ref => fields.
  def filled(id)
    cells = tab(id)&.get_map("cells").to_h # nil.to_h is {}
    cells.select do |ref, cell|
      cell.is_a?(Hash) && SheetSpec::CELL.match?(ref) && cell.keys.intersect?(SHOWN)
    end
  end
end
