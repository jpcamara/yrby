# The tools a sheet agent's model works the sheet with. Each write goes
# through the agent (SheetWrites), which outlines the block it's writing,
# moves its cursor to each cell, writes it in its own edit, and waits a
# moment, so people watch every change land.
module SheetTools
  TAB = { type: "string", description: "The tab's name. Leave it out for the tab the person is on." }.freeze
  FILL = "A fill color: #{SheetSpec::FILLS.keys.join(", ")}, none, or #rrggbb. " \
         "Use a color on a header and its light version on the cells under it.".freeze
  FORMAT = "How a number shows: number (21,000), percent (0.1 shows 10%), currency ($21,000), " \
           "+number (+4,200) or +percent (+10%) for a change or difference, text, or auto".freeze
  CELL = {
    type: "object",
    properties: {
      ref: { type: "string", description: "The cell, such as B4" },
      input: { type: "string",
               description: "What to type: text, a number, or a formula starting with =. Empty clears the input." },
      format: { type: "string", description: FORMAT },
      bold: { type: "boolean" },
      fill: { type: "string", description: FILL }
    },
    required: %w[ref]
  }.freeze

  def self.all(agent)
    [ReadSheet, WriteCells, FormatRange, ClearRange, ResizeColumns, AddTab, RenameTab].map { |tool| tool.new(agent) }
  end

  class Tool < RubyLLM::Tool
    def self.tool_name = name.split("::").last.gsub(/(?<=[a-z])(?=[A-Z])/, "_").downcase

    def initialize(agent)
      super()
      @agent = agent
    end

    # Some models send an array or object argument as a JSON string, or a
    # list of JSON strings. Decode those so the tool gets what it declared.
    def call(tool_call: nil, **arguments)
      super(tool_call:, **arguments.transform_values { |value| decode(value) })
    end

    private

    def decode(value)
      case value
      when Array then value.map { |each| decode(each) }
      when /\A\s*[\[{]/ then decode(JSON.parse(value))
      else value
      end
    rescue JSON::ParserError
      value
    end
  end

  class ReadSheet < Tool
    description "Lists a tab's non-empty cells, row by row, as `B4: input (format, bold, fill)`, or every tab's " \
                "when you leave out the tab. You see what people typed, not computed values: an input starting " \
                "with = is a formula, and only people's browsers compute it, so work out any number you need " \
                "from the inputs. Cells marked yours are ones you wrote for this ask. People keep editing while " \
                "you work, so read again before changing what they might have changed."
    parameters(type: "object", properties: {
                 tab: { type: "string", description: "The tab's name. Leave it out to read every tab." },
                 range: { type: "string", description: "Only these cells, such as A1:G20" }
               })

    def execute(tab: nil, range: nil) = @agent.read_sheet(tab:, range:)
  end

  class WriteCells < Tool
    description "Writes cells on one tab, one at a time in the order given, while people watch. Each cell can set " \
                "its input, format, bold, and fill; what you leave out stays as it is. Formulas: + - * / ^ & " \
                "and comparisons, A1, $A$1, A1:C9, whole columns (C:C), other tabs (Historical!C2, " \
                "'Last year'!A1:A9), and #{SheetSpec::FUNCTIONS.join(", ")}. Write a block, such as a table's " \
                "header row and its rows, per call, in reading order. Returns the range written and any formula " \
                "that names a function or tab the sheet doesn't have."
    parameters(type: "object", properties: { tab: TAB, cells: { type: "array", items: CELL } }, required: %w[cells])

    def execute(cells:, tab: nil) = @agent.write_cells(cells, tab:)
  end

  class FormatRange < Tool
    description "Sets the format, bold, or fill of every cell in a range at once, empty cells too, such as a " \
                "light fill down a column under its header. Give only what to change."
    parameters(type: "object", properties: {
                 tab: TAB, range: { type: "string", description: "Such as C2:C6" },
                 format: { type: "string", description: FORMAT }, bold: { type: "boolean" },
                 fill: { type: "string", description: FILL }
               }, required: %w[range])

    def execute(range:, tab: nil, **style) = @agent.format_range(range, tab:, **style)
  end

  class ClearRange < Tool
    description "Empties every cell in a range: inputs and formatting."
    parameters(type: "object", properties: { tab: TAB, range: { type: "string", description: "Such as A10:G20" } },
               required: %w[range])

    def execute(range:, tab: nil) = @agent.clear_range(range, tab:)
  end

  class ResizeColumns < Tool
    description "Sets column widths in pixels. Columns start at 110. A label takes about 7 pixels a " \
                "character plus 16, so size a column to its longest label, and no wider."
    parameters(type: "object", properties: {
                 tab: TAB,
                 columns: { type: "array", items: {
                   type: "object",
                   properties: { column: { type: "string", description: "A column letter, such as A" },
                                 width: { type: "number", description: "Pixels, 40 to 600" } },
                   required: %w[column width]
                 } }
               }, required: %w[columns])

    def execute(columns:, tab: nil) = @agent.resize_columns(columns, tab:)
  end

  class AddTab < Tool
    description "Adds an empty tab at the end. Write to it with its name as the tab."
    parameter :name, description: "The new tab's name"

    def execute(name:) = @agent.add_tab(name)
  end

  class RenameTab < Tool
    description "Renames a tab. Formulas that name it follow it."
    parameter :tab, description: "The tab's name now"
    parameter :name, description: "Its new name"

    def execute(tab:, name:) = @agent.rename_tab(tab, name)
  end
end
