# What the sheet agent writes, from its model: cell writes as JSON lines,
# streamed. Like AgentModel, which it builds on for the budget, the retry on
# a stall, and the short error messages, it asks Fireworks when
# FIREWORKS_API_KEY is set, and otherwise streams a canned forecast built
# from the seeded Historical tab, so the demo runs without a key.
class SheetModel < AgentModel
  FILL = <<~TEXT.freeze
    You're working in a shared spreadsheet that people are editing live. Here
    is every non-empty cell, tab by tab, as `CELL: input`. An input that starts
    with = is a formula.

    %<sheet>s

    %<asker>s is looking at the tab "%<tab>s"%<selection>s. They asked:

    %<prompt>s
    %<previous>s
    Answer by writing cells. Reply with only JSON objects, one per line, in
    the order to write them, nothing else:

    {"cell":"B4","input":"=SUMIFS(Historical!C:C, Historical!A:A, A4)","format":"number"}

    Fields: cell (A1 style, on the tab "%<tab>s" unless you add "tab" with
    another tab's name), input (what to type: text, a number, or a formula),
    and optionally format (number, percent, currency, or text), bold (true or
    false), and fill (gray, blue, green, amber, or rose) for header bands.
    Write a percent as a fraction (0.1) with format percent. To clear a cell,
    write "input":"".

    Formulas support + - * / ^ & comparisons, A1, $A$1, A1:C9, C:C,
    Historical!A1 and 'Tab name'!A1, and SUM AVERAGE MIN MAX COUNT ROUND ABS
    IF SUMIF SUMIFS. Prefer formulas that reference other cells and tabs over
    numbers you computed, so the sheet stays live. Put labels in column A and
    a header row above any table. Don't overwrite cells people wrote unless
    they asked you to. Last, add one line {"say":"..."} with a sentence on
    what you did.
  TEXT

  PREVIOUS = <<~TEXT.freeze

    This is a follow-up. You already wrote cells for their earlier ask
    ("%s"); they're in the listing above. Change them the way they ask now.
  TEXT

  def self.for(agent) = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new : new(agent)

  # Streams the model's reply to `prompt` about `sheet` (the listing from
  # SheetAgent#listing). `tab` is the name of the tab the person is on and
  # `selection` the cell they had selected.
  def fill(sheet:, tab:, prompt:, asker:, selection: nil, previous: nil, &) # rubocop:disable Metrics/ParameterLists -- the sheet and the ask's parts
    selection = selection ? ", with #{selection} selected" : ""
    previous = previous.to_s.empty? ? "" : format(PREVIOUS, previous)
    stream(format(FILL, sheet:, tab:, selection:, prompt:, asker:, previous:), &)
  end

  # Without a key: a pre-order forecast on the tab the person is on, below
  # anything already there, with every number a formula over the Historical
  # tab the page seeds (frontend/src/sheet_seed.js). It streams a line at a
  # time, the way the model does.
  class Canned
    CHANNELS = [["Website", 0.05, 0.15], ["Email list", 0.08, 0.2], ["Gift boxes", 0.1, 0.3],
                ["Grocery partners", 0.0, 0.1]].freeze

    def fill(sheet:, tab:, **)
      top = first_free_row(sheet, tab)
      self.class.forecast(top).each do |line|
        sleep 0.03
        yield "#{line.to_json}\n"
      end
    end

    HEADERS = [["A", "Channel", "gray"], ["B", "2025 actual", "gray"], ["C", "Conservative growth", "blue"],
               ["D", "Conservative", "blue"], ["E", "Optimistic growth", "green"], ["F", "Optimistic", "green"],
               ["G", "Difference", "amber"]].freeze

    # The forecast's cells, starting on row `top`: a title, a header band,
    # a row per channel, totals, and what the totals mean for the kitchen.
    def self.forecast(top = 1)
      first = top + 3
      last = first + CHANNELS.size - 1
      [{ cell: "A#{top}", input: "Holiday pies: 2026 pre-order forecast", bold: true },
       { cell: "A#{top + 1}", input: "From last year's orders on the Historical tab", format: "text" },
       *HEADERS.map { |col, label, fill| { cell: "#{col}#{top + 2}", input: label, bold: true, fill: } },
       *CHANNELS.each_with_index.flat_map { |channel, i| channel_row(first + i, *channel) },
       *total_row(last + 1, first, last), *meaning(last + 3, last + 1, first),
       { say: "(No model key, so this is the canned forecast.) Built it from last year's numbers on " \
              "Historical: each channel's 2025 total, grown by a conservative and an optimistic rate." }]
    end

    def self.channel_row(row, channel, low, high)
      [{ cell: "A#{row}", input: channel },
       { cell: "B#{row}", input: "=SUMIFS(Historical!C:C, Historical!A:A, A#{row})", format: "number" },
       { cell: "C#{row}", input: low.to_s, format: "percent" },
       { cell: "D#{row}", input: "=ROUND(B#{row}*(1+C#{row}), 0)", format: "number" },
       { cell: "E#{row}", input: high.to_s, format: "percent" },
       { cell: "F#{row}", input: "=ROUND(B#{row}*(1+E#{row}), 0)", format: "number" },
       { cell: "G#{row}", input: "=F#{row}-D#{row}", format: "number" }]
    end

    def self.total_row(row, first, last)
      sums = %w[B D F].map { |col| [col, "=SUM(#{col}#{first}:#{col}#{last})", "number"] }
      growth = [["C", "=D#{row}/B#{row}-1", "percent"], ["E", "=F#{row}/B#{row}-1", "percent"]]
      [{ cell: "A#{row}", input: "Total", bold: true },
       *(sums + growth + [["G", "=F#{row}-D#{row}", "number"]]).map do |col, input, format|
         { cell: "#{col}#{row}", input:, format:, bold: true }
       end]
    end

    # Kitchen capacity is Historical!C16 and gift boxes in stock C17
    # (frontend/src/sheet_seed.js). Gift boxes are the third channel.
    def self.meaning(row, total, first)
      [{ cell: "A#{row}", input: "What it means", bold: true, fill: "rose" },
       { cell: "B#{row}", input: "", fill: "rose" },
       { cell: "A#{row + 1}", input: "Kitchen days at full capacity, conservative" },
       { cell: "B#{row + 1}", input: "=ROUND(D#{total}/Historical!C16, 1)" },
       { cell: "A#{row + 2}", input: "Kitchen days at full capacity, optimistic" },
       { cell: "B#{row + 2}", input: "=ROUND(F#{total}/Historical!C16, 1)" },
       { cell: "A#{row + 3}", input: "Gift boxes left if the optimistic case lands" },
       { cell: "B#{row + 3}", input: "=Historical!C17-F#{first + 2}", format: "number" },
       { cell: "A#{row + 4}", input: "Extra pies to plan for, optimistic over conservative" },
       { cell: "B#{row + 4}", input: "=G#{total}", format: "number" }]
    end

    private

    # One row below the last row the tab uses, or row 1 on an empty tab.
    def first_free_row(sheet, tab)
      section = sheet[/^Tab "#{Regexp.escape(tab)}".*?(?=^Tab "|\z)/m].to_s
      last = section.scan(/^[A-Z]+(\d+):/).flatten.map(&:to_i).max
      last ? last + 2 : 1
    end
  end
end
