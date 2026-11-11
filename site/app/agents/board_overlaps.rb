# Where a board agent's items collide, for the feedback its tools give the
# model. BoardContents includes it.
module BoardOverlaps
  SOLID = %w[note text shape sticker].freeze # frames hold things; lines cross them

  # ", but it overlaps a, b" when the item `key` covers another solid item,
  # so the model can move one of them. Empty otherwise. Frames count when an
  # item crosses their edge, not when it sits inside.
  def overlap_note(key)
    all = items.to_h.select { |_id, thing| thing.is_a?(Hash) && (SOLID + ["frame"]).include?(thing["type"]) }
    mine = all.delete(key) or return ""
    box = box_of(mine)
    hits = all.filter_map { |other, thing| other if collide?(mine, box, thing, box_of(thing)) }
    hits.empty? ? "" : ", but it overlaps #{hits.first(5).join(", ")}"
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
end
