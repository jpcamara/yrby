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

  # --- the agent's tools ---

  LISTED = 200 # items the model reads in one look

  # Everything on the board as the model reads it: the title, then one line
  # per item, top to bottom. Items the ask `id` added say so.
  def listing(id) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- a header and lines
    title = @doc.get_text("title").to_s
    subtitle = @doc.get_text("subtitle").to_s
    all = items.to_h.select { |_key, item| item.is_a?(Hash) && item["type"] }
    lines = all.sort_by { |_key, item| [item["y"].to_f, item["x"].to_f] }.first(LISTED).map do |key, item|
      BoardSpec.describe(key, item, mine: item["ask"] == id)
    end
    head = title.empty? ? "The board has no title." : "Title: #{title}#{" / #{subtitle}" unless subtitle.empty?}"
    more = all.size > LISTED ? ["(#{all.size - LISTED} more items not listed)"] : []
    [head, lines.empty? ? "The board is empty." : "Items (#{all.size}):", *lines, *more].join("\n")
  end

  def item(key) = (map = items.get_map(key)) && map.to_h

  def exists?(key) = !item(key).nil?

  # Items stack by z; frames go under the rest.
  # `stamp` holds its z, the ask that added it, and who did ("by").
  def create(key, fields, text, stamp)
    items[key] = fields.merge(stamp)
    items.get_map(key).set_text("text", text) if text
  end

  def change(key, fields, text)
    map = items.get_map(key)
    fields.each { |field, value| map[field] = value }
    map.set_text("text", text) if text
  end

  def delete(key) = items.delete(key)

  # The connectors that join `key` to anything.
  def attached(key)
    items.to_h.filter_map do |other, item|
      other if item.is_a?(Hash) && item["type"] == "connector" && [item["from"], item["to"]].include?(key)
    end
  end

  # Where the cursor goes for an item: its middle, a connector's middle, or a
  # path's start.
  def center(item)
    if item["type"] == "connector"
      ends = [item["from"], item["to"]].filter_map { |key| item(key) }.map { |end_| center(end_) }
      return ends.transpose.map { |values| values.sum / values.size } if ends.any?
    end
    [item["x"].to_f + (item["w"].to_f / 2), item["y"].to_f + (item["h"].to_f / 2)].map(&:round)
  end

  SOLID = %w[note text shape sticker].freeze # frames hold things; lines cross them

  # ", but it overlaps a, b" when the item `key` covers another solid item,
  # so the model can move one of them. Empty otherwise.
  def overlap_note(key)
    solid = items.to_h.select { |_id, thing| thing.is_a?(Hash) && SOLID.include?(thing["type"]) }
    mine = solid.delete(key) or return ""
    box = box_of(mine)
    hits = solid.filter_map { |other, thing| other if overlap?(box, box_of(thing)) }
    hits.empty? ? "" : ", but it overlaps #{hits.first(5).join(", ")}"
  end

  def box_of(thing) = thing.values_at("x", "y", "w", "h").map(&:to_f)

  # The ids of what the ask `id` added.
  def added_by(id) = items.to_h.filter_map { |key, item| key if item.is_a?(Hash) && item["ask"] == id }

  def title_words = [@doc.get_text("title").to_s, @doc.get_text("subtitle").to_s]

  def retitle(title, subtitle)
    [[@doc.get_text("title"), title], [@doc.get_text("subtitle"), subtitle]].each do |text, words|
      text.delete(0, text.length) unless text.empty?
      text.push(words) unless words.empty?
    end
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
