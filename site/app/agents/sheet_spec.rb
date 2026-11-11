# Turns what a sheet agent's model asks for into cell fields, and cells back
# into the short lines the model reads. It knows cell and range names, the
# formats and fills the page draws, and enough about formulas to tell the
# model when one names a function or tab the sheet doesn't have. It never
# computes a value: only the browsers do (frontend/src/formula.js).
#
# Anything it can't use raises SheetSpec::Invalid with a reason the model can
# act on.
module SheetSpec # rubocop:disable Metrics/ModuleLength -- one rule per field reads best flat
  class Invalid < StandardError; end

  CELL = /\A\$?([A-Z]{1,2})\$?([1-9]\d{0,2})\z/ # A1 to ZZ999
  FORMATS = %w[number percent currency text +number +percent].freeze
  # The fills the model can name: a header color, and a light one for the
  # cells under it. The page's toolbar offers the header colors.
  FILLS = {
    "gray" => "#ececec", "blue" => "#dbe7fb", "green" => "#d7f0dd", "yellow" => "#fbe8c4", "pink" => "#f9dbe0",
    "purple" => "#e9e0f7",
    "light gray" => "#f6f6f6", "light blue" => "#eff4fd", "light green" => "#eef8f1", "light yellow" => "#fdf5e6",
    "light pink" => "#fcf0f2", "light purple" => "#f5f0fc"
  }.freeze
  ALIASES = { "amber" => "yellow", "rose" => "pink" }.freeze
  NAMES = FILLS.invert.freeze
  # The functions formula.js has. test/sheet_agent_test.rb checks they match.
  FUNCTIONS = %w[SUM AVERAGE MIN MAX COUNT ABS ROUND IF SUMIF SUMIFS].freeze
  MAX_INPUT = 500
  MAX_AREA = 2000 # cells in one range

  module_function

  # [column index from 0, row from 1] for "B4", or raises.
  def ref(name)
    m = CELL.match(name.to_s.strip.upcase) or raise Invalid, "#{name.to_s.inspect} isn't a cell like B4"
    [m[1].each_char.reduce(0) { |n, ch| (n * 26) + ch.ord - 64 } - 1, m[2].to_i]
  end

  def name(col, row)
    letters = +""
    col += 1
    while col.positive?
      col, rest = (col - 1).divmod(26)
      letters.prepend((65 + rest).chr)
    end
    "#{letters}#{row}"
  end

  # [c1, r1, c2, r2] for "A1:G6" or "B4", or raises.
  def range(text)
    first, last = text.to_s.split(":", 2)
    c1, r1 = ref(first)
    c2, r2 = last ? ref(last) : [c1, r1]
    c1, c2 = [c1, c2].minmax
    r1, r2 = [r1, r2].minmax
    raise Invalid, "#{text} is more than #{MAX_AREA} cells" if (c2 - c1 + 1) * (r2 - r1 + 1) > MAX_AREA

    [c1, r1, c2, r2]
  end

  def cells_in(text)
    c1, r1, c2, r2 = range(text)
    (r1..r2).flat_map { |row| (c1..c2).map { |col| name(col, row) } }
  end

  def covers?(bounds, cell)
    c1, r1, c2, r2 = bounds
    col, row = ref(cell)
    col.between?(c1, c2) && row.between?(r1, r2)
  end

  # The smallest range holding every cell in `refs`, as "A1:G6", or "B4".
  def bounds(refs)
    spots = refs.map { |cell| ref(cell) }
    cols = spots.map(&:first).minmax
    rows = spots.map(&:last).minmax
    first = name(cols[0], rows[0])
    last = name(cols[1], rows[1])
    first == last ? first : "#{first}:#{last}"
  end

  # The fields a cell write sets: input, format, bold, and fill, each only if
  # given. A nil value removes that field from the cell.
  def fields(spec)
    spec = spec.to_h.transform_keys(&:to_s)
    out = {}
    out["input"] = input(spec["input"]) if spec.key?("input")
    out.merge!(style(spec))
    raise Invalid, "give an input, format, bold, or fill" if out.empty?

    out
  end

  # The formatting fields in `spec`: format, bold, and fill.
  def style(spec) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- one check per field
    spec = spec.to_h.transform_keys(&:to_s)
    out = {}
    if spec.key?("format") && !spec["format"].nil?
      format = spec["format"].to_s.strip.downcase
      unless FORMATS.include?(format) || format == "auto"
        raise Invalid,
              "format must be one of #{FORMATS.join(", ")}, or auto"
      end

      out["format"] = format == "auto" ? nil : format
    end
    out["bold"] = spec["bold"] ? true : nil if spec.key?("bold") && !spec["bold"].nil?
    out["fill"] = fill(spec["fill"]) if spec.key?("fill") && !spec["fill"].nil?
    out
  end

  def input(value)
    unless value.nil? || value.is_a?(String) || value.is_a?(Numeric)
      raise Invalid,
            "an input is text, a number, or a formula"
    end

    text = value.is_a?(Float) && value == value.round ? value.round.to_s : value.to_s
    text = text.strip[0, MAX_INPUT]
    text.empty? ? nil : text
  end

  # A named fill, #rrggbb, or nil for "none".
  def fill(value)
    value = value.to_s.strip.downcase.tr("_-", "  ")
    return nil if ["", "none", "no fill", "clear"].include?(value)
    return value if value.match?(/\A#\h{6}\z/)

    value = ALIASES.fetch(value, value)
    FILLS.fetch(value) { raise Invalid, "fill must be one of #{FILLS.keys.join(", ")}, none, or #rrggbb" }
  end

  # One line for the model: "B4: =SUM(B1:B3) (number, bold, fill blue)".
  def describe(ref, cell, mine: false) # rubocop:disable Metrics/CyclomaticComplexity -- one check per field
    style = []
    style << cell["format"] if cell["format"]
    style << "bold" if cell["bold"]
    style << "fill #{NAMES[cell["fill"]] || cell["fill"]}" if cell["fill"]
    style << "yours" if mine
    input = cell["input"].to_s.tr("\n", " ")
    "#{ref}: #{input.empty? ? "(empty)" : input}#{" (#{style.join(", ")})" unless style.empty?}"
  end

  # What's wrong with a formula that the sheet can tell without computing it:
  # functions it doesn't have, and tabs that don't exist. Empty when nothing.
  def problems(input, tabs)
    return [] unless input.to_s.start_with?("=")

    code = input.gsub(/"[^"]*"/, '""')
    unknown = code.scan(/(?<![\w.!'])([A-Za-z][\w.]*)\s*\(/).flatten.map(&:upcase).uniq - FUNCTIONS
    missing = tab_names(code).reject { |tab| tabs.any? { |name| name.casecmp?(tab) } }
    [*unknown.map { |fn| "#{fn} isn't a function here (there's #{FUNCTIONS.join(", ")})" },
     *missing.map { |tab| "there's no tab named #{tab}" }]
  end

  TAB_REF = /(?<![\w.'])(?:'((?:[^']|'')+)'|([A-Za-z_][\w.]*))!/

  def tab_names(code) = code.scan(TAB_REF).map { |quoted, plain| quoted ? quoted.gsub("''", "'") : plain }.uniq

  # Rewrites the tab references in a formula after the tab `from` is renamed
  # `to`, as renameTab in formula.js does. Text in strings stays.
  def rename(input, from, to) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- strings, quoted names, and plain ones
    return input unless input.is_a?(String) && input.start_with?("=")

    name = to.match?(/\A[A-Za-z_][\w.]*\z/) ? to : "'#{to.gsub("'", "''")}'"
    input.split(/("[^"]*"?)/).map do |part|
      next part if part.start_with?('"')

      part.gsub(TAB_REF) do |match|
        quoted, plain = Regexp.last_match.captures
        (quoted&.gsub("''", "'") || plain).casecmp?(from) ? "#{name}!" : match
      end
    end.join
  end
end
