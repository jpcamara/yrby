require "json"
require "securerandom"

# Places a board agent's plan on the board. The model writes the plan as JSON
# lines, one thing per line, and says what to draw but not where. Each line
# that arrives becomes the board items for it, with their places, so the
# agent can draw them while the rest of the plan is still streaming:
#
#   {"kind":"title","text":"Huckleberry Pie launch","subtitle":"From flavor to delivery"}
#   {"kind":"group","text":"Recipe"}
#   {"kind":"step","label":"Day 1","title":"Lock flavor","caption":"Pick the final recipe","icon":"🥧"}
#   {"kind":"note","title":"Farmers market","caption":"Sample slices on Saturday","icon":"🧺"}
#   {"kind":"finale","title":"Holiday delivery","caption":"Pies at every door","icon":"🎁"}
#
# Steps go along a winding dashed path, left to right and back, with a pill
# for each label and a sticky note under it. A group starts a new row, and
# when it ends a frame goes around its notes. Notes go in a grid. A finale
# ends the path in a larger area. Lines it can't read are skipped.
#
# Coordinates are board units from `origin`, the top left of the area the
# agent was given. BoardLayout::Places has where
# things go, and BoardLayout::Items what each looks like.
class BoardLayout
  include Items
  include Places

  # One item to write: its id, its fields, the text for its Y.Text (or nil),
  # and the point the agent's cursor moves to while it draws it.
  Item = Data.define(:id, :fields, :text, :at)
  # The board's own title and subtitle, for a board that has none yet.
  Title = Data.define(:text, :subtitle, :at)

  KINDS = %w[title group step note finale].freeze
  DX = 270      # between steps along a row
  DY = 330      # between rows
  PER_ROW = 4
  HEAD = 150    # room above the first row for a heading
  TURN = 150    # how far a turn swings out past the last step of a row
  GRID_GAP = 36
  MAX_ITEMS = 80

  attr_reader :count, :lines

  # `titled` says whether the board already has a title. If it does, a title
  # line becomes a heading on the board instead. `above` is the z this
  # drawing stacks up from.
  def initialize(origin:, titled: false, above: 0, id: -> { SecureRandom.alphanumeric(12) })
    @ox, @oy = origin
    @titled = titled
    @z = above
    @id = id
    @count = 0
    @lines = []
    @groups = 0
    @group = nil  # { name:, color:, boxes: [] } while a group is open
    @mode = nil   # :steps or :notes
    @bottom = @oy + HEAD - 60
  end

  # The items one line of the plan adds, in drawing order. Empty for a
  # blank line, a code fence, or a line it can't read.
  def add(line)
    entry = parse(line) or return []
    placed = send(:"add_#{entry["kind"]}", entry) or return []

    @lines << JSON.generate(entry)
    placed
  end

  # Closes the group that's still open. Call it once the plan has ended.
  def finish = close_group

  private

  def parse(line)
    text = line.to_s.strip
    return unless text.start_with?("{") && @count < MAX_ITEMS

    entry = JSON.parse(text)
    entry if entry.is_a?(Hash) && KINDS.include?(entry["kind"])
  rescue JSON::ParserError
    nil
  end

  # Each kind returns its items, or nil when the line is missing what it
  # needs.
  def add_title(entry)
    text = clean(entry["text"], 60)
    return if text.empty?

    subtitle = clean(entry["subtitle"], 120)
    return [Title.new(text:, subtitle:, at: [@ox, @oy])] unless @titled

    heading([@ox, @oy], text, subtitle)
  end

  # A group starts a new row. The frame goes around it once it ends, so it
  # can fit what's in it.
  def add_group(entry)
    name = clean(entry["text"] || entry["title"], 40)
    return if name.empty?

    closed = close_group
    @group = { name:, color: color(entry["color"], COLORS.keys[@groups % COLORS.size]), boxes: [] }
    @groups += 1
    @new_row = true
    closed
  end

  # A step without a label is a note on the path, and has no pill.
  def add_step(entry, pill: true)
    heading = clean(entry["title"], 40)
    return if heading.empty?

    switch_to(:steps)
    advance
    left, top = @last
    label = clean(entry["label"], 16).presence || ("Step #{@steps}" if pill)
    note = note_at([left - (NOTE_W / 2), top + (PILL_H / 2) + 18], entry, heading)
    remember(note)
    [@segment, (pill(@last, label) if label), note].compact
  end

  # Notes go in a grid, unless the plan is drawing a path: then they go
  # along it.
  def add_note(entry)
    return add_step(entry, pill: false) if @mode == :steps

    heading = clean(entry["title"], 40)
    return if heading.empty?

    switch_to(:notes)
    note = note_at(next_cell, entry, heading)
    remember(note)
    [note]
  end

  # The end of the path: a pill, then a larger area with the finale's icon
  # and caption.
  def add_finale(entry)
    heading = clean(entry["title"], 40)
    return if heading.empty?

    closed = close_group
    switch_to(:steps)
    advance
    area = finale_area(@last, entry, heading)
    @bottom = [@bottom, area.first.fields["y"] + area.first.fields["h"]].max
    [*closed, @segment, pill(@last, clean(entry["label"], 16).presence || "Done"), *area]
  end

  def remember(note)
    @group[:boxes] << note.fields if @group
    @bottom = [@bottom, note.fields["y"] + note.fields["h"]].max
  end

  # The frame around the group that's open, if it has anything in it. Above
  # steps it leaves room for their pills.
  def close_group
    group = @group
    @group = nil
    return [] if group.nil? || group[:boxes].empty?

    [frame_around(group[:boxes], group[:name], group[:color], pills: @mode == :steps)]
  end
end
