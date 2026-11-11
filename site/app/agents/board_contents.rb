# A board agent's view of the board document: what's on it, where a new
# drawing fits, what the model is told about it, and the writes that put a
# drawing on it. The writes go inside the agent's edit.
class BoardContents
  AREA = [1200, 1100].freeze # about what a drawing covers, to keep it clear of what's there
  BELOW = 160                # the gap above a drawing that goes under everything
  CONTEXT = 40               # items the model hears about

  def initialize(doc)
    @doc = doc
  end

  def items = @doc.get_map("items")

  # Where the ask `id` draws: where it drew before, for a redraw. Else the
  # top left of what the person could see, unless that would land on what's
  # there, and then below everything.
  def origin(id, ask)
    saved = ask["origin"]
    return point(saved).map(&:to_i) if saved.is_a?(Hash)

    wanted = point(ask["at"]).map(&:round)
    boxes = boxes(id)
    boxes.any? { |box| overlap?(box, [*wanted, *AREA]) } ? below(boxes) : wanted
  end

  def top_z = items.to_h.values.filter_map { |item| item["z"] if item.is_a?(Hash) }.max.to_i

  # The board's title and the words on it, leaving out what the ask `id`
  # drew, since a redraw replaces that.
  def summary(id)
    title = @doc.get_text("title").to_s
    words = others(id).filter_map do |item|
      text = item["text"].to_s.gsub(/\s+/, " ").strip
      "- #{item["type"]}: #{text[0, 80]}" unless text.empty?
    end
    [("Title: #{title}" unless title.empty?), *words.first(CONTEXT)].compact.join("\n")
  end

  def titled? = !@doc.get_text("title").empty?

  # Writes one BoardLayout::Item, marked with the ask that drew it and who
  # did.
  def put(item, ask:, by:)
    items[item.id] = item.fields.merge("ask" => ask, "by" => by)
    items.get_map(item.id).set_text("text", item.text) if item.text
  end

  # Sets the board's title and subtitle from a BoardLayout::Title.
  def title(item)
    [[@doc.get_text("title"), item.text], [@doc.get_text("subtitle"), item.subtitle]].each do |text, words|
      text.delete(0, text.length) unless text.empty?
      text.push(words)
    end
  end

  # Removes what the ask `id` drew.
  def remove(id)
    items.to_h.each { |key, item| items.delete(key) if item.is_a?(Hash) && item["ask"] == id }
  end

  private

  def others(id) = items.to_h.values.select { |item| item.is_a?(Hash) && item["ask"] != id }

  def boxes(id) = others(id).map { |item| item.values_at("x", "y", "w", "h").map(&:to_f) }

  def below(boxes) = [boxes.map(&:first).min.round, (boxes.map { |_, top, _, height| top + height }.max + BELOW).round]

  def point(hash) = (hash.is_a?(Hash) ? hash : {}).values_at("x", "y").map(&:to_f)

  def overlap?(one, two)
    one[0] < two[0] + two[2] && two[0] < one[0] + one[2] && one[1] < two[1] + two[3] && two[1] < one[1] + one[3]
  end
end
