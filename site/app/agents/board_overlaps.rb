# What covers what on the board, so a board agent's model can see its
# layout the way people do. BoardContents includes it.
#
# Every item takes up room: a note, text, shape, sticker, or frame its box,
# and a path or connector its line, as thick as it's drawn. Two items
# overlap when that room meets, except where it's meant to:
#
# - an item sitting inside a frame (crossing its edge counts),
# - an item riding a road it was put `on`,
# - a connector touching the items it joins,
# - two lines crossing, or a line crossing a frame,
# - and, for an ask, something someone else put on top of its items (a
#   reaction sticker on a note): they put it there on purpose.
module BoardOverlaps
  LINES = %w[path connector].freeze
  SHRINK = [1, 0.8, 0.6].freeze # the sizes a rider on a road tries, to fit
  STEP = 10 # board units between the points checked along a line
  SHOWN = 12 # overlaps listed at once

  # ", but it overlaps a (note "Call the mill"), ..." when the item `key`
  # overlaps others, so the model can move one of them. Empty otherwise.
  def overlap_note(key)
    all = solid_items
    mine = all.delete(key) or return ""
    hits = to_fix(key, mine, all)
    hits.empty? ? "" : ", but it overlaps #{hits.first(5).map { |id| label(id, all[id]) }.join(", ")}"
  end

  # Every overlap on the board that involves an item the ask `id` added, one
  # per line, or nil when there are none. Leaves out what someone else put
  # on top of the ask's items.
  def overlaps(id)
    all = solid_items
    pairs = all.select { |_key, thing| thing["ask"] == id }.flat_map do |key, thing|
      to_fix(key, thing, all.except(key)).map { |other| [key, other].sort }
    end.uniq
    return if pairs.empty?

    lines = pairs.first(SHOWN).map { |one, two| "- #{label(one, all[one])} and #{label(two, all[two])}" }
    [*lines, *(["- and #{pairs.size - SHOWN} more"] if pairs.size > SHOWN)].join("\n")
  end

  # The ids among `all` that the item `key`, `mine`, overlaps.
  def hits(key, mine, all)
    all.filter_map { |other, thing| other if other != key && meet?([key, mine], [other, thing]) }
  end

  def inside?(box, outer)
    box[0] >= outer[0] && box[1] >= outer[1] && box[0] + box[2] <= outer[0] + outer[2] &&
      box[1] + box[3] <= outer[1] + outer[3]
  end

  def box_of(thing) = thing.values_at("x", "y", "w", "h").map(&:to_f)

  # The box [x, y, w, h] that centers `mine`, of `size`, on the road `path`
  # (id `road`), so a truck or a pill sits on the road: at the road's point
  # nearest `near` where it covers nothing, smaller if it has to be (down to
  # SHRINK), else at the nearest point.
  def onto_road(road, near, size, mine:, skip: nil)
    path = item(road)
    others = solid_items.except(skip)
    rider = mine.merge("on" => road)
    SHRINK.each do |scale|
      wanted = size.map { |length| (length * scale).round }
      spot = spots(path, near, wanted).find do |x, y|
        hits(skip, rider.merge("x" => x, "y" => y, "w" => wanted[0], "h" => wanted[1]), others).empty?
      end
      return [*spot.first(2), *wanted] if spot
    end
    [*spots(path, near, size).first.first(2), *size]
  end

  private

  # What the item `key`, `mine`, overlaps among `all`, less what someone
  # else put on top of it.
  def to_fix(key, mine, all)
    hits(key, mine, all).reject { |other| all[other]["ask"] != mine["ask"] && all[other]["z"].to_f > mine["z"].to_f }
  end

  def solid_items = items.to_h.select { |_key, thing| thing.is_a?(Hash) && thing["type"] }

  # A short name for an item: its id, type, and a few of its words or what
  # it pictures.
  def label(key, thing)
    words = thing["text"].to_s.gsub(/\s+/, " ").strip[0, 30].presence || thing["drawing"] || thing["icon"]
    "#{key} (#{thing["type"]}#{" #{words.inspect}" if words})"
  end

  # Whether the room two [key, item] pairs take up meets.
  def meet?((one_key, one), (two_key, two))
    lines = [one, two].count { |thing| LINES.include?(thing["type"]) }
    return false if lines == 2
    return line_meets?(*(LINES.include?(one["type"]) ? [one_key, one, two_key, two] : [two_key, two, one_key, one])) if
      lines == 1

    boxes_meet?(one, two)
  end

  def boxes_meet?(one, two)
    a = box_of(one)
    b = box_of(two)
    return false unless overlap?(a, b)
    return true unless [one, two].any? { |thing| thing["type"] == "frame" }

    !inside?(a, b) && !inside?(b, a)
  end

  # Whether the line `line` (id `line_key`) runs over the box item `thing`.
  def line_meets?(line_key, line, key, thing)
    return false if thing["type"] == "frame" || thing["on"] == line_key
    return false if line["type"] == "connector" && [line["from"], line["to"]].include?(key)

    half = line["type"] == "path" ? line["stroke"].to_f / 2 : 1
    x, y, w, h = box_of(thing)
    grown = [x - half, y - half, w + (2 * half), h + (2 * half)]
    line_points(line).any? { |px, py| inside?([px, py, 0, 0], grown) }
  end

  # Points every STEP along a path, or along a connector between the middles
  # of the items it joins, leaving out the parts inside those items.
  def line_points(line)
    return along(path_corners(line)) if line["type"] == "path"

    ends = [line["from"], line["to"]].map { |key| item(key) }
    return [] unless ends.all?

    along(ends.map { |end_| center(end_) }).reject do |point|
      ends.any? do |end_|
        inside?([*point, 0, 0], box_of(end_))
      end
    end
  end

  def path_corners(path)
    Array(path["points"]).map(&:to_f).each_slice(2).map { |px, py| [path["x"].to_f + px, path["y"].to_f + py] }
  end

  def along(corners)
    corners.each_cons(2).flat_map do |(x1, y1), (x2, y2)|
      steps = [(Math.hypot(x2 - x1, y2 - y1) / STEP).ceil, 1].max
      (0..steps).map { |i| [x1 + ((x2 - x1) * i / steps), y1 + ((y2 - y1) * i / steps)] }
    end
  end

  # The top lefts that center a box of `size` on each point along `path`,
  # nearest `near` first, with how far each is from it.
  def spots(path, near, size)
    half = size.map { |length| length / 2.0 }
    along(path_corners(path)).map do |x, y|
      [(x - half[0]).round, (y - half[1]).round, Math.hypot(x - near[0], y - near[1])]
    end
                             .sort_by(&:last)
  end

  def overlap?(one, two)
    one[0] < two[0] + two[2] && two[0] < one[0] + one[2] && one[1] < two[1] + two[3] && two[1] < one[1] + one[3]
  end
end
