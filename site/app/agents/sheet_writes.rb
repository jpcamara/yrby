# Reads the sheet agent's model reply as it streams in: cell writes, as JSON
# objects, ideally one per line. Code fences, a wrapping array, or several
# objects on one line are fine too, because the reader takes each balanced
# {...} as soon as its closing brace arrives. Anything that isn't a valid
# write is dropped.
#
#   reader = SheetWrites.new
#   reader << '{"cell":"B4","input":"=SUM(B1:B3)",'  # => []
#   reader << '"format":"number"}'                    # => [#<data Write cell="B4" ...>]
class SheetWrites
  FORMATS = %w[number percent currency text].freeze
  # The fills the model can name. The page offers the same colors.
  FILLS = { "gray" => "#ececec", "blue" => "#dbe7fb", "green" => "#d7f0dd", "amber" => "#fbe8c4",
            "rose" => "#f9dbe0" }.freeze
  CELL = /\A\$?([A-Z]{1,2})\$?([1-9]\d{0,2})\z/ # A1 to ZZ999
  MAX_INPUT = 500

  Write = Data.define(:tab, :cell, :input, :format, :bold, :fill)
  Say = Data.define(:text)

  # One object from the reply as a Write or a Say, or nil.
  def self.parse(json)
    data = JSON.parse(json)
    return unless data.is_a?(Hash)

    data.key?("cell") ? write(data) : say(data)
  rescue JSON::ParserError
    nil
  end

  def self.say(data) = (Say.new(data["say"].strip[0, 400]) if data["say"].is_a?(String))

  def self.write(data)
    cell = CELL.match(data["cell"].to_s.upcase.strip) or return
    input = data["input"]
    return unless input.nil? || input.is_a?(String) || input.is_a?(Numeric)

    Write.new(cell: "#{cell[1]}#{cell[2]}", input: input.to_s[0, MAX_INPUT], **optional(data))
  end

  # The fields a write can leave out, as nil when they're missing or wrong.
  def self.optional(data)
    { tab: (data["tab"].strip[0, 40] if data["tab"].is_a?(String)),
      format: (data["format"] if FORMATS.include?(data["format"])),
      bold: (data["bold"] if [true, false].include?(data["bold"])),
      fill: fill(data["fill"]) }
  end

  # A named fill or a #rrggbb color.
  def self.fill(value) = FILLS[value.to_s.downcase] || value.to_s[/\A#\h{6}\z/]

  def initialize
    @buffer = +""
    @at = 0          # how far into the buffer it has read
    @depth = 0       # brace depth
    @start = nil     # where the current top-level object starts
    @in_string = false
    @escaped = false
  end

  # Feeds a chunk of the reply and returns the complete writes and Says in it.
  def <<(chunk)
    @buffer << chunk
    found = []
    while @at < @buffer.size
      read(@buffer[@at], found)
      @at += 1
    end
    forget_read_text
    found.filter_map { |json| self.class.parse(json) }
  end

  private

  def read(char, found)
    return read_string(char) if @in_string

    case char
    when '"' then @in_string = @depth.positive?
    when "{" then open
    when "}" then close(found)
    end
  end

  def read_string(char)
    if @escaped then @escaped = false
    elsif char == "\\" then @escaped = true
    elsif char == '"' then @in_string = false
    end
  end

  def open
    @start = @at if @depth.zero?
    @depth += 1
  end

  def close(found)
    return if @depth.zero?

    @depth -= 1
    found << @buffer[@start..@at] if @depth.zero?
  end

  # Between objects, nothing read so far is needed again.
  def forget_read_text
    return unless @depth.zero?

    @buffer = +""
    @at = 0
  end
end
