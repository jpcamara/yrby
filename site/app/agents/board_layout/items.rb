class BoardLayout
  # What each thing BoardLayout places looks like: the fields of a pill, a
  # note, a stretch of path, a frame, a sticker, or a line of text, and the
  # cleaning of what the model wrote into them. Points are [x, y] in board
  # units.
  module Items
    COLORS = {
      "yellow" => "#fde68a", "blue" => "#bfdbfe", "pink" => "#fbcfe8",
      "green" => "#bbf7d0", "purple" => "#ddd6fe", "orange" => "#fed7aa"
    }.freeze
    PATH_COLOR = "#94a3b8".freeze
    PILL_COLOR = "#1f2937".freeze
    NOTE_W = 200
    NOTE_H = 132
    PILL_W = 92
    PILL_H = 34

    private

    def pill(center, label)
      left, top = center
      item({ "type" => "shape", "shape" => "pill", "x" => left - (PILL_W / 2), "y" => top - (PILL_H / 2),
             "w" => PILL_W, "h" => PILL_H, "color" => PILL_COLOR }, label, at: center)
    end

    # A note with its top left at `corner`: the title on the first line and
    # the caption under it, with the icon above both.
    def note_at(corner, entry, heading)
      left, top = corner
      caption = clean(entry["caption"], 80)
      fields = { "type" => "note", "x" => left, "y" => top, "w" => NOTE_W, "h" => NOTE_H,
                 "color" => color(entry["color"], @group&.dig(:color) || "yellow") }
      fields["icon"] = icon(entry["icon"]) if icon(entry["icon"])
      item(fields, caption.empty? ? heading : "#{heading}\n#{caption}", at: [left + (NOTE_W / 2), top + (NOTE_H / 2)])
    end

    # The path sits under the pills and notes it joins. Its points are from
    # its top left, so moving it only changes x and y.
    def path(points)
      left = points.map(&:first).min
      top = points.map(&:last).min
      relative = points.map { |px, py| [(px - left).round, (py - top).round] }
      fields = { "type" => "path", "points" => relative.flatten, "color" => PATH_COLOR, "stroke" => 3, "dash" => true,
                 "x" => left, "y" => top, "w" => relative.map(&:first).max, "h" => relative.map(&:last).max }
      item(fields, nil, at: points.last, stack: @z - 500 + @count)
    end

    # Frames go under everything else.
    def frame(box, label, color)
      left, top, width, height = box
      item({ "type" => "frame", "x" => left, "y" => top, "w" => width, "h" => height, "color" => color }, label,
           at: [left + 20, top + 16], stack: @z - 1000 + @count)
    end

    # A frame around notes, with room above for their pills when they're
    # steps.
    def frame_around(boxes, label, color, pills:)
      left = boxes.map { |b| b["x"] }.min - 28
      top = boxes.map { |b| b["y"] }.min - (pills ? PILL_H + 66 : 56)
      right = boxes.map { |b| b["x"] + b["w"] }.max + 28
      bottom = boxes.map { |b| b["y"] + b["h"] }.max + 24
      frame([left, top, right - left, bottom - top], label, color)
    end

    # The end of the path, under its pill: an area named for it, with its
    # icon and caption.
    def finale_area(center, entry, heading)
      middle, top = center
      left = middle - 140
      top = top + (PILL_H / 2) + 18
      width = 280
      height = 210
      caption = clean(entry["caption"], 80)
      [frame([left, top, width, height], heading, color(entry["color"], "green")),
       sticker([middle, top + 84], icon(entry["icon"]) || "🎉"),
       (words([left + 20, top + 136, width - 40, 50], caption, size: 16, align: "center") unless caption.empty?)]
        .compact
    end

    def heading(corner, text, subtitle)
      left, top = corner
      [words([left, top, 900, 44], text, size: 32),
       (words([left, top + 48, 900, 28], subtitle, size: 17) unless subtitle.empty?)].compact
    end

    def sticker(center, emoji, size: 80)
      left, top = center
      item({ "type" => "sticker", "x" => left - (size / 2), "y" => top - (size / 2), "w" => size, "h" => size,
             "icon" => emoji }, nil, at: center)
    end

    def words(box, text, size:, align: "left")
      left, top, width, height = box
      item({ "type" => "text", "x" => left, "y" => top, "w" => width, "h" => height, "size" => size, "align" => align },
           text, at: [left + 10, top + (height / 2)])
    end

    def item(fields, text, at:, stack: nil)
      @count += 1
      @z += 1
      fields = fields.merge("z" => stack || @z).transform_values { |v| v.is_a?(Float) ? v.round : v }
      Item.new(id: @id.call, fields:, text:, at: at.map(&:round))
    end

    # A palette name or a hex color, else the fallback, which is either.
    def color(name, fallback)
      name.to_s.match?(/\A#\h{6}\z/) ? name.to_s : COLORS.fetch(name.to_s.downcase) { COLORS.fetch(fallback, fallback) }
    end

    # One emoji, or nil. Letters, digits, and punctuation aren't icons.
    def icon(value)
      first = value.to_s.strip.grapheme_clusters.first
      first if first && first.bytesize <= 32 && !first.match?(/\A[\p{L}\p{N}\p{P}\s]/)
    end

    def clean(value, max) = value.to_s.gsub(/\s+/, " ").strip[0, max].to_s
  end
end
