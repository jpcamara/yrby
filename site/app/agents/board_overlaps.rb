# Where a board agent's items collide, for the feedback its tools give the
# model. BoardContents includes it.
module BoardOverlaps
  SOLID = %w[note text shape sticker].freeze # frames hold things; lines cross them
  BOXES = (SOLID + ["frame"]).freeze
  ON_ROADS = %w[note sticker].freeze # pills and labels sit on a road on purpose
  ROAD = 8 # a path this thick or more is a road that notes shouldn't cover

  # ", but it overlaps a, b" when the item `key` covers another solid item or
  # sits on a road, so the model can move one of them. Empty otherwise.
  # Frames count when an item crosses their edge, not when it sits inside.
  def overlap_note(key)
    all = items.to_h.select { |_id, thing| thing.is_a?(Hash) }
    mine = all.delete(key)
    return "" unless mine && BOXES.include?(mine["type"])

    hits = hits(mine, box_of(mine), all)
    hits.empty? ? "" : ", but it overlaps #{hits.first(5).join(", ")}"
  end

  # What `mine`, at `box`, covers among `all` the other items.
  def hits(mine, box, all)
    all.filter_map do |other, thing|
      if BOXES.include?(thing["type"])
        other if collide?(mine, box, thing, box_of(thing))
      elsif on_road?(mine, box, thing)
        "the road #{other}"
      end
    end
  end

  def collide?(mine, box, other, other_box)
    return false unless overlap?(box, other_box)
    return true if [mine, other].all? { |thing| SOLID.include?(thing["type"]) }

    !inside?(box, other_box) && !inside?(other_box, box)
  end

  def inside?(box, outer)
    box[0] >= outer[0] && box[1] >= outer[1] && box[0] + box[2] <= outer[0] + outer[2] &&
      box[1] + box[3] <= outer[1] + outer[3]
  end

  def box_of(thing) = thing.values_at("x", "y", "w", "h").map(&:to_f)

  private

  def overlap?(one, two)
    one[0] < two[0] + two[2] && two[0] < one[0] + one[2] && one[1] < two[1] + two[3] && two[1] < one[1] + one[3]
  end

  # Whether a note or sticker covers part of a thick path: any point along
  # the path, every few units, inside the box grown by half the path's width.
  def on_road?(mine, box, path)
    return false unless ON_ROADS.include?(mine["type"]) && path["type"] == "path" && path["stroke"].to_i >= ROAD

    half = path["stroke"].to_f / 2
    x, y, w, h = box
    grown = [x - half, y - half, w + (2 * half), h + (2 * half)]
    road_points(path).any? { |px, py| inside?([px, py, 0, 0], grown) }
  end

  def road_points(path)
    flat = Array(path["points"]).map(&:to_f)
    points = flat.each_slice(2).map { |px, py| [path["x"].to_f + px, path["y"].to_f + py] }
    points.each_cons(2).flat_map do |(x1, y1), (x2, y2)|
      steps = [(Math.hypot(x2 - x1, y2 - y1) / 10).ceil, 1].max
      (0..steps).map { |i| [x1 + ((x2 - x1) * i / steps), y1 + ((y2 - y1) * i / steps)] }
    end
  end
end
