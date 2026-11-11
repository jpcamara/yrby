# What the sheet agent does, from its model. Like AgentModel, which it builds
# on for the budget, the retry on a stall, and the short error messages, it
# asks Fireworks when FIREWORKS_API_KEY is set. The model works the sheet
# through the agent's tools (SheetTools) and says what it did. Without a key
# it builds a canned forecast from the seeded Historical tab through the same
# writes, so the demo runs without a key.
class SheetModel < AgentModel
  PROMPT = <<~TEXT.freeze
    %<asker>s asked you, in a shared spreadsheet: %<prompt>s
    %<previous>s
    They're on the tab "%<tab>s"%<selection>s. The tabs:
    %<sheet>s

    Do what they asked with the tools. Before your first tool call, say a
    short acknowledgement of two to four words, such as "You got it." Then
    read the tabs you need with read_sheet before you write.

    Build it the way a good analyst builds a spreadsheet:
    - Work on their tab unless they name another. On an empty tab start at
      A1; otherwise start two rows below what's there. Don't overwrite cells
      people wrote unless they asked you to.
    - Answer what they asked about and no more: a forecast of orders is
      about orders, not revenue or prices, unless they ask.
    - A table has one header row, bold, with a fill on every header. Columns
      that belong together share a color (a rate and the result it drives),
      the label column gets its own, and the cells under each header get the
      light version of its color, label column included, so the table reads
      in bands.
    - Labels go in the first column, one row per item, then a bold Total row.
    - Every number that comes from other numbers is a formula, never a number
      you worked out: pull source data with references (for example SUMIFS
      over another tab) and compute from cells. Use all the source data
      that applies, such as a whole season, unless they ask for part of it. Put assumptions, such as
      rates, in their own cells as typed values so people can change them.
      Round computed counts with ROUND(..., 0). A total of rates is a
      formula too, such as total new / total old - 1.
    - A forecast is a range, not one guess: a conservative case and an
      optimistic case, each a rate column followed by the result it drives,
      then a Difference column (optimistic minus conservative).
    - Formats: percent for rates (type 0.1 for 10%%), number for counts
      (it shows whole numbers, so leave a value with decimals on auto),
      currency for money, +percent for growth rates, +number for
      differences.
    - For a forecast, comparison, or analysis, leave a blank row under the
      table and add a short "What it means" section. Its header row puts
      each case's name over that case's result column in the table above,
      in the same color, and Difference over the difference column.
      Each row under it is one plain takeaway, labeled with the figure it
      uses, in under 40 characters (such as "Weeks of work, at 300 a week"),
      and turns the totals into what people decide with, from numbers
      already in the sheet such as a capacity or what's in stock: one
      formula under each case, and the difference.
    - Keep headers and labels short, in whole words (no abbreviations), and
      widen a column only as far as its
      longest label needs, so the whole table fits on one screen (about
      1,000 pixels across).
    - Write a block per write_cells call, header row first, in reading order,
      so people can follow along. The tools tell you about formulas the sheet
      can't compute; fix them.
    When you're done, reply in one plain sentence of at most 25 words saying
    what you built. No markdown.
  TEXT

  PREVIOUS = <<~TEXT.freeze

    This is a change to their earlier ask, "%<previous>s". Then you said:
    %<said>s
    read_sheet marks the cells you wrote for it as yours. Change them, or the
    sheet, the way they ask now.
  TEXT

  def self.for(agent) = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new(agent) : new(agent)

  # Works the sheet for `prompt` through the agent's tools, and streams what
  # the model says. `sheet` is the agent's overview of the tabs, `tab` the
  # name of the tab the person is on, and `selection` the cell they had
  # selected. `previous` and `said` are the earlier prompt and what the agent
  # said then, for a change.
  def work(prompt:, asker:, tab:, sheet:, selection: nil, previous: nil, said: nil, &) # rubocop:disable Metrics/ParameterLists -- the sheet and the ask's parts
    selection = selection ? ", with #{selection} selected" : ""
    previous = previous.to_s.empty? ? "" : format(PREVIOUS, previous:, said: said.to_s.presence || "(nothing)")
    stream(format(PROMPT, asker:, prompt:, previous:, tab:, selection:, sheet:), &)
  end

  # Without a key: a pre-order forecast on the tab the person is on, below
  # anything already there, with every number a formula over the Historical
  # tab the page seeds (frontend/src/sheet_seed.js), written through the same
  # writes the tools make.
  class Canned
    CHANNELS = [["Website", 0.1, 0.3], ["Email list", 0.05, 0.25], ["Gift boxes", 0.0, 0.2],
                ["Grocery partners", 0.1, 0.3]].freeze
    HEADERS = [["Channel", "pink"], ["2025 actual", "gray"], ["Conservative growth", "blue"],
               ["Conservative", "blue"], ["Optimistic growth", "green"], ["Optimistic", "green"],
               ["Difference", "yellow"]].freeze
    COLUMNS = %w[A B C D E F G].freeze
    TINTS = HEADERS.each_with_index.to_h { |(_, fill), i| [COLUMNS[i], "light #{fill}"] }.freeze

    def initialize(agent)
      @agent = agent
    end

    def work(**)
      yield "You got it."
      @agent.read_sheet(tab: "Historical")
      top = @agent.free_row
      self.class.blocks(top).each { |cells| @agent.write_cells(cells) }
      @agent.resize_columns([{ "column" => "A", "width" => 240 }])
      yield "(No model key, so this is the canned forecast.) Built it from last year's numbers on Historical: " \
            "each channel's 2025 total, grown by a conservative and an optimistic rate."
    end

    # The forecast's cells from row `top`, in blocks: the header row, the
    # channels and their total, and what the totals mean for the kitchen.
    def self.blocks(top = 1)
      first = top + 1
      last = first + CHANNELS.size - 1
      total = last + 1
      [header(top, HEADERS),
       CHANNELS.each_with_index.flat_map do |channel, i|
         channel_row(first + i, *channel)
       end + total_row(total, first, last),
       meaning(total + 2, total)]
    end

    def self.header(row, labels)
      labels.each_with_index.map do |(label, fill), i|
        { "ref" => "#{COLUMNS[i]}#{row}", "input" => label, "bold" => true, "fill" => fill }.compact
      end
    end

    def self.channel_row(row, channel, low, high)
      [["A", channel], ["B", "=SUMIFS(Historical!C:C, Historical!A:A, A#{row})", "number"],
       ["C", format("%g", low), "+percent"], ["D", "=ROUND(B#{row}*(1+C#{row}), 0)", "number"],
       ["E", format("%g", high), "+percent"], ["F", "=ROUND(B#{row}*(1+E#{row}), 0)", "number"],
       ["G", "=F#{row}-D#{row}", "+number"]].map do |col, input, format|
        { "ref" => "#{col}#{row}", "input" => input, "format" => format, "fill" => TINTS[col] }.compact
      end
    end

    def self.total_row(row, first, last)
      [["A", "Total", nil], ["B", "=SUM(B#{first}:B#{last})", "number"], ["C", "=D#{row}/B#{row}-1", "+percent"],
       ["D", "=SUM(D#{first}:D#{last})", "number"], ["E", "=F#{row}/B#{row}-1", "+percent"],
       ["F", "=SUM(F#{first}:F#{last})", "number"], ["G", "=F#{row}-D#{row}", "+number"]].map do |col, input, format|
        { "ref" => "#{col}#{row}", "input" => input, "format" => format, "bold" => true, "fill" => TINTS[col] }.compact
      end
    end

    # The full line's capacity is Historical!C16 and pie boxes in stock C17
    # (frontend/src/sheet_seed.js).
    def self.meaning(row, total)
      labels = ["What it means", nil, nil, "Conservative", nil, "Optimistic", "Difference"]
      head = header(row, labels.zip(HEADERS.map(&:last)))
      rows = [["Days on the full line", "=ROUND(D#{total}/Historical!C16, 1)", "=ROUND(F#{total}/Historical!C16, 1)"],
              ["Boxes left, of what's in stock", "=Historical!C17-D#{total}", "=Historical!C17-F#{total}"]]
      head + rows.each_with_index.flat_map do |(label, low, high), i|
        r = row + 1 + i
        [{ "ref" => "A#{r}", "input" => label }, { "ref" => "D#{r}", "input" => low, "fill" => "light blue" },
         { "ref" => "F#{r}", "input" => high, "fill" => "light green" },
         { "ref" => "G#{r}", "input" => "=F#{r}-D#{r}", "format" => "+number", "fill" => "light yellow" }]
      end
    end
  end
end
