# Turns what a board agent's model asks for into board item fields, and back
# into the short lines the model reads. The model names items and places them
# itself, in board units; this only checks and cleans what it wrote:
#
#   { "type" => "note", "x" => 100, "y" => 80, "color" => "yellow", "icon" => "🥧",
#     "title" => "Lock flavor", "caption" => "Pick the final recipe" }
#
# Types are note, text, shape, frame, sticker, connector, and path, with the
# fields frontend/src/board.js draws. Anything else it can't use raises
# BoardSpec::Invalid with a reason the model can act on.
module BoardSpec # rubocop:disable Metrics/ModuleLength -- one rule per field reads best flat
  class Invalid < StandardError; end

  TYPES = %w[note text shape frame sticker connector path].freeze
  COLORS = BoardLayout::Items::COLORS
  NAMES = COLORS.invert.freeze
  SIZES = { "note" => [200, 132], "text" => [360, 40], "shape" => [160, 90], "frame" => [640, 420],
            "sticker" => [80, 80] }.freeze
  DEFAULT_COLOR = { "note" => "#fde68a", "shape" => "#ffffff", "frame" => "#fef9c3", "connector" => "#475569",
                    "path" => "#1f2937" }.freeze
  SHAPES = %w[rect ellipse pill].freeze
  LIMIT = 20_000 # how far from the middle of the board anything goes
  MAX_TEXT = 300

  module_function

  # The fields and text for a new item. `exists` answers whether an id is on
  # the board, for a connector's ends.
  def create(spec, exists:)
    spec = spec.to_h.transform_keys(&:to_s)
    type = spec["type"].to_s
    raise Invalid, "type must be one of #{TYPES.join(", ")}" unless TYPES.include?(type)

    fields = { "type" => type }
    case type
    when "connector" then connector(fields, spec, exists)
    when "path" then path(fields, spec)
    else box(fields, spec, type)
    end
    fields["color"] = color(spec["color"], DEFAULT_COLOR[type]) if DEFAULT_COLOR[type] || spec["color"]
    fields.compact!
    [fields, text(type, spec)]
  end

  # The fields and text (nil to leave it) that change an item of `type`.
  # `was` is the item's text now, so changing a note's caption keeps its title.
  def update(type, spec, was: "") # rubocop:disable Metrics -- one check per field
    spec = spec.to_h.transform_keys(&:to_s)
    if type == "note" && (spec.key?("title") ^ spec.key?("caption")) && !spec.key?("text")
      title, caption = was.to_s.split("\n", 2)
      spec = { "title" => title, "caption" => caption }.merge(spec)
    end
    fields = {}
    %w[x y w h].each { |key| fields[key] = number(spec[key], key) if spec.key?(key) }
    fields["color"] = color(spec["color"], nil) if spec["color"]
    fields["icon"] = icon(spec["icon"]) if spec.key?("icon")
    fields["shape"] = shape(spec["shape"]) if spec["shape"] && type == "shape"
    fields["size"] = spec["size"].to_i.clamp(12, 72) if spec["size"] && type == "text"
    fields["align"] = align(spec["align"]) if spec["align"] && type == "text"
    fields["dash"] = spec["dash"] == true if spec.key?("dash") && %w[path connector].include?(type)
    words = %w[text title caption].any? { |key| spec.key?(key) } ? text(type, spec) : nil
    [fields.compact, words]
  end

  # One line for the model: id, type, place and size, color, icon, and text.
  def describe(id, item, mine: false) # rubocop:disable Metrics -- one check per field
    type = item["type"]
    parts = ["#{id} #{type}"]
    parts << if type == "connector"
               "from #{item["from"]} to #{item["to"]}"
             else
               "x=#{item["x"].to_i} y=#{item["y"].to_i} w=#{item["w"].to_i} h=#{item["h"].to_i}"
             end
    parts << (NAMES[item["color"]] || item["color"]) if item["color"]
    parts << item["shape"] if item["shape"] && item["shape"] != "rect"
    parts << "size #{item["size"]}" if item["size"]
    parts << item["icon"] if item["icon"]
    words = item["text"].to_s.gsub(/\s*\n\s*/, " / ").gsub(/\s+/, " ").strip
    parts << words[0, 100].inspect unless words.empty?
    parts << "(a pen stroke)" if type == "path"
    parts << "(yours, from this ask)" if mine
    parts.join(" ")
  end

  def box(fields, spec, type) # rubocop:disable Metrics -- one check per field
    width, height = SIZES.fetch(type)
    fields["x"] = number(spec["x"], "x")
    fields["y"] = number(spec["y"], "y")
    fields["w"] = spec["w"] ? number(spec["w"], "w").clamp(20, 4000) : width
    fields["h"] = spec["h"] ? number(spec["h"], "h").clamp(20, 4000) : height
    fields["w"] = fields["h"] = [fields["w"], fields["h"]].max if type == "sticker"
    fields["icon"] = icon(spec["icon"]) if %w[note sticker].include?(type)
    raise Invalid, "a sticker needs an emoji icon" if type == "sticker" && !fields["icon"]

    fields["shape"] = shape(spec["shape"]) if type == "shape"
    return unless type == "text"

    fields["size"] = (spec["size"] || 20).to_i.clamp(12, 72)
    fields["align"] = align(spec["align"])
  end

  def connector(fields, spec, exists)
    %w[from to].each do |key|
      id = spec[key].to_s
      raise Invalid, "a connector's #{key} must be the id of an item on the board" unless exists.call(id)

      fields[key] = id
    end
    raise Invalid, "a connector can't join an item to itself" if fields["from"] == fields["to"]

    fields["dash"] = true if spec["dash"]
  end

  # Points arrive as [[x, y], ...] in board units and are stored from the
  # path's top left, as the browser stores a pen stroke.
  def path(fields, spec) # rubocop:disable Metrics -- one check per field
    points = Array(spec["points"]).filter_map do |point|
      x, y = point.is_a?(Hash) ? point.values_at("x", "y") : Array(point)
      [number(x, "a point's x"), number(y, "a point's y")] if x && y
    end.first(400)
    raise Invalid, "a path needs at least two points, as [[x, y], ...]" if points.size < 2

    left = points.map(&:first).min
    top = points.map(&:last).min
    relative = points.map { |x, y| [x - left, y - top] }
    fields.merge!("x" => left, "y" => top, "w" => relative.map(&:first).max, "h" => relative.map(&:last).max,
                  "points" => relative.flatten, "stroke" => (spec["stroke"] || 3).to_i.clamp(1, 16))
    fields["dash"] = true if spec["dash"]
  end

  # A note's text is its title line, then its caption.
  def text(type, spec) # rubocop:disable Metrics -- the note's two lines, or one label
    return nil if %w[connector path sticker].include?(type)

    words = if type == "note" && (spec["title"] || spec["caption"])
              [spec["title"], spec["caption"]].map { |part| clean(part) }.reject(&:empty?).join("\n")
            else
              (spec["text"] || spec["title"]).to_s.strip.gsub(/[ \t]+/, " ")[0, MAX_TEXT]
            end
    words.to_s
  end

  def number(value, name)
    raise Invalid, "#{name} must be a number" unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(\.\d+)?\z/)

    value.to_f.round.clamp(-LIMIT, LIMIT)
  end

  def color(value, fallback)
    value = value.to_s.strip.downcase
    return value if value.match?(/\A#\h{6}\z/)

    COLORS.fetch(value) { fallback }
  end

  def icon(value)
    first = value.to_s.strip.grapheme_clusters.first
    first if first && first.bytesize <= 32 && !first.match?(/\A[\p{L}\p{N}\p{P}\s]/)
  end

  def shape(value) = SHAPES.include?(value.to_s) ? value.to_s : "rect"
  def align(value) = %w[left center right].include?(value.to_s) ? value.to_s : "left"
  def clean(value) = value.to_s.gsub(/\s+/, " ").strip[0, 120]
end
