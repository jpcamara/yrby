require "json"

# What a sheet agent's tools do, for the ask it's answering (@ask, asked on
# the tab @tab): read the sheet, and write, format, and clear cells, size
# columns, and add and rename tabs. SheetAgent includes it; SheetTools and
# the canned forecast call it.
#
# Before it writes a block of cells it selects the block, so people see its
# range outlined in its color, then writes each cell in its own edit with its
# cursor there, a moment apart. Every change keeps what the ask's Undo needs
# (see SheetAgent), and each tool call sets the ask's `doing`, the line its
# card shows while it works.
module SheetWrites # rubocop:disable Metrics/ModuleLength -- one method per tool, and the change they share
  MAX_CHANGES = 400 # cells per ask
  MAX_PER_CALL = 200 # cells in one write_cells call
  MAX_WIDTH = 600

  def read_sheet(tab: nil, range: nil)
    @acted = true
    if tab.to_s.strip.empty?
      doing("Reading the sheet")
      return sheet.tab_ids.map { |id| sheet.listing(id, mine: @ask) }.join("\n\n")
    end

    id = tab_id(tab)
    doing("Reading #{sheet.tab_name(id)}#{" #{range}" if range.present?}")
    sheet.listing(id, range: range.presence, mine: @ask)
  rescue SheetSpec::Invalid => e
    "Couldn't read: #{e.message}"
  end

  # Writes each cell in order, and returns what it wrote, what it skipped
  # and why, and any formula the sheet can't compute.
  def write_cells(cells, tab: nil)
    id = tab_id(tab)
    writes, notes = prepare(Array(cells).first(MAX_PER_CALL))
    notes << "Only the first #{MAX_PER_CALL} cells were used." if Array(cells).size > MAX_PER_CALL
    return ["Wrote nothing.", *notes].join("\n") if writes.empty?

    range = SheetSpec.bounds(writes.map(&:first))
    doing("Writing #{where(id, range)}")
    writes.each do |ref, fields|
      step(id, ref, range:) { keeping(id, ref) { sheet.set_cell(id, ref, stamped(fields)) } }
    end
    ["Wrote #{writes.size} cell#{"s" unless writes.size == 1} on #{sheet.tab_name(id)}, in #{range}.",
     *formula_notes(id, writes), *notes].join("\n")
  rescue SheetSpec::Invalid => e
    "Wrote nothing: #{e.message}"
  end

  # Sets format, bold, or fill on every cell in `range`, in one change.
  def format_range(range, tab: nil, **style)
    id = tab_id(tab)
    fields = SheetSpec.style(style)
    return "Nothing to change: give format, bold, or fill." if fields.empty?

    refs = SheetSpec.cells_in(range)
    doing("Formatting #{where(id, range)}")
    step(id, refs.first, range:, count: refs.size) do
      refs.each { |ref| keeping(id, ref) { sheet.set_cell(id, ref, fields) } }
    end
    "Formatted #{range} on #{sheet.tab_name(id)}."
  rescue SheetSpec::Invalid => e
    "Formatted nothing: #{e.message}"
  end

  # Empties every cell in `range`, inputs and formatting, in one change.
  def clear_range(range, tab: nil)
    id = tab_id(tab)
    refs = SheetSpec.cells_in(range).select { |ref| sheet.cell(id, ref) }
    return "#{range} on #{sheet.tab_name(id)} is already empty." if refs.empty?

    doing("Clearing #{where(id, range)}")
    step(id, refs.first, range:, count: refs.size) do
      refs.each { |ref| keeping(id, ref) { sheet.clear_cell(id, ref) } }
    end
    "Cleared #{refs.size} cell#{"s" unless refs.size == 1} in #{range} on #{sheet.tab_name(id)}."
  rescue SheetSpec::Invalid => e
    "Cleared nothing: #{e.message}"
  end

  # Sets column widths, from [{ column, width }], in one change.
  def resize_columns(columns, tab: nil)
    id = tab_id(tab)
    widths = Array(columns).filter_map { |each| width_of(each) }
    return "Resized nothing: give each column as a letter and a width in pixels." if widths.empty?

    doing("Sizing columns on #{sheet.tab_name(id)}")
    step(id, "#{widths.first.first}1") do
      widths.each { |column, width| keeping(id, "width:#{column}") { sheet.set_width(id, column, width) } }
    end
    "Set #{widths.map { |column, width| "#{column} to #{width}px" }.join(", ")}."
  rescue SheetSpec::Invalid => e
    "Resized nothing: #{e.message}"
  end

  def add_tab(name)
    name = tab_title(name)
    raise SheetSpec::Invalid, "there's already a tab named #{name}" if sheet.tab_named(name)

    doing("Adding the tab #{name}")
    id = nil
    step(nil, "A1") do
      id = sheet.add_tab(name)
      ask = sheet.ask(@ask)
      ask["addedTabs"] = JSON.generate([*JSON.parse(ask["addedTabs"] || "[]"), id])
    end
    "Added the tab #{name}."
  rescue SheetSpec::Invalid => e
    "Added no tab: #{e.message}"
  end

  def rename_tab(tab, name)
    id = tab_id(tab)
    from = sheet.tab_name(id)
    name = tab_title(name)
    other = sheet.tab_named(name)
    raise SheetSpec::Invalid, "there's already a tab named #{name}" if other && other != id

    doing("Renaming #{from} to #{name}")
    step(id, "A1") { renaming(id, from, name) }
    "Renamed #{from} to #{name}, and the formulas that named it."
  rescue SheetSpec::Invalid => e
    "Renamed nothing: #{e.message}"
  end

  # For the canned forecast: the first row clear of what's on the ask's tab,
  # a row apart from it.
  def free_row
    used = sheet.listing(@tab).lines.drop(1).filter_map { |line| line[/\A[A-Z]+(\d+):/, 1]&.to_i }.max
    used ? used + 2 : 1
  end

  private

  def sheet = SheetDocument.new(doc)

  # The tab named `name`, or the ask's tab when it's blank.
  def tab_id(name)
    return @tab if name.to_s.strip.empty?

    sheet.tab_named(name) or raise SheetSpec::Invalid,
                                   "there's no tab named #{name}; the tabs are #{sheet.tab_names.join(", ")}"
  end

  def tab_title(name)
    name = name.to_s.gsub(/[!\s]+/, " ").strip[0, 40]
    raise SheetSpec::Invalid, "a tab needs a name" if name.empty?

    name
  end

  def where(id, range) = id == @tab ? range : "#{range} on #{sheet.tab_name(id)}"

  # [[ref, fields]] for the cells the model gave, and why any were skipped.
  def prepare(cells)
    notes = []
    writes = cells.each_with_index.filter_map do |spec, i|
      spec = spec.to_h.transform_keys(&:to_s)
      [SheetSpec.name(*SheetSpec.ref(spec["ref"])), SheetSpec.fields(spec)]
    rescue SheetSpec::Invalid => e
      notes << "#{spec["ref"].presence || "cell #{i + 1}"}: skipped, #{e.message}"
      nil
    end
    [writes, notes]
  end

  # [column, pixels] from the model's { column, width }, or nil.
  def width_of(spec)
    spec = spec.to_h.transform_keys(&:to_s)
    column = spec["column"].to_s.strip.upcase
    [column, spec["width"].to_i.clamp(40, MAX_WIDTH)] if column.match?(/\A[A-Z]{1,2}\z/) && spec["width"]
  end

  # A new input is the agent's, marked with the ask.
  def stamped(fields) = fields.key?("input") ? fields.merge("by" => name, "ask" => @ask) : fields

  def formula_notes(id, writes)
    tabs = sheet.tab_names
    notes = writes.flat_map do |ref, fields|
      SheetSpec.problems(fields["input"], tabs).map { |problem| "#{ref}: #{problem}" }
    end
    notes.empty? ? [] : ["Check these formulas on #{sheet.tab_name(id)}:", *notes]
  end

  def renaming(id, from, to)
    ask = sheet.ask(@ask)
    renamed = JSON.parse(ask["renamedTabs"] || "{}")
    renamed[id] = [renamed.dig(id, 0) || from, to]
    after = sheet.child_map(ask, "after")
    sheet.rename_tab(id, to) do |tab, ref|
      key = "#{tab}!#{ref}"
      after[key] = JSON.generate(sheet.cell(tab, ref)) if after[key].present?
    end
    ask["renamedTabs"] = JSON.generate(renamed)
  end

  # What the agent is doing, on the ask's card. It also puts there what the
  # model has said so far, such as "You got it." before its first tool call.
  def doing(text)
    raise AgentModel::Stopped unless working?(@ask)

    edit { sheet.update(@ask, "doing" => text, **said) }
  end

  # One change to the cell `ref` on tab `id`: the agent's cursor goes there,
  # with `range` outlined, the change happens in one edit, and the agent
  # waits so people see it. Raises Stopped once people stopped or undid the
  # ask.
  def step(id, ref, range: nil, count: 1)
    @acted = true
    raise AgentModel::Stopped unless working?(@ask)
    if @changes + count > MAX_CHANGES
      raise SheetSpec::Invalid, "this ask has changed #{@changes} cells and can change #{MAX_CHANGES}; stop and reply"
    end

    point(id, ref, range) if id
    edit do
      yield
      ask = sheet.ask(@ask)
      ask["written"] = ask["written"].to_i + count
    end
    @changes += count
    sleep @pace
  end

  # Around one change to a cell (or "width:B", a column's width) on tab
  # `id`: keeps it as it was before this ask first changed it, and as the ask
  # left it, as JSON ("" for empty), so Undo can put it back unless someone
  # changed it since.
  def keeping(id, ref)
    ask = sheet.ask(@ask)
    key = "#{id}!#{ref}"
    before = sheet.child_map(ask, "before")
    before[key] = snapshot(id, ref) unless before.key?(key)
    yield
    sheet.child_map(ask, "after")[key] = snapshot(id, ref)
  end

  def snapshot(id, ref)
    if ref.start_with?("width:")
      sheet.width(id, ref.delete_prefix("width:")).to_s
    else
      (cell = sheet.cell(id, ref)) ? JSON.generate(cell) : ""
    end
  end
end
