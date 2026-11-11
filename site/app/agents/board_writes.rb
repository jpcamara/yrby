require "json"
require "securerandom"

# What a board agent's tools do, for the ask it's answering (@ask): read the
# board, and add, change, delete, and retitle, one change at a time with the
# cursor on it. BoardAgent includes it; BoardTools and the canned plan call
# it. Every write keeps what the ask's Undo needs (see BoardAgent).
module BoardWrites
  MAX_PER_CALL = 60 # items or changes in one tool call

  def board_listing
    doing("Looking at the board")
    board.listing(@ask).tap { @acted = true }
  end

  # Adds each item and returns one line per item: its new id, or why it was
  # skipped. A connector may name an earlier item of the same call by its ref.
  def add_items(specs)
    doing("Adding #{count(specs.size, "item")}")
    refs = {}
    lines = specs.first(MAX_PER_CALL).each_with_index.map do |spec, i|
      spec = spec.to_h.transform_keys(&:to_s)
      name = spec["ref"].presence || "item #{i + 1}"
      add_spec(spec, refs).then { |key| "#{name}: added as #{key}#{collisions(key)}" }
    rescue BoardSpec::Invalid => e
      "#{name}: skipped, #{e.message}"
    end
    [*lines, *(["Only the first #{MAX_PER_CALL} were used."] if specs.size > MAX_PER_CALL)].join("\n")
  end

  # Adds one item the model described, remembering its ref for connectors.
  def add_spec(spec, refs)
    %w[from to].each { |end_| spec[end_] = refs.fetch(spec[end_].to_s, spec[end_]) if spec[end_] }
    fields, text = BoardSpec.create(spec, exists: ->(key) { board.exists?(key) })
    key = add(fields, text)
    refs[spec["ref"].to_s] = key if spec["ref"].present?
    key
  end

  # Adds one item from finished fields, for the tools and the canned plan.
  def add(fields, text)
    key = SecureRandom.alphanumeric(10)
    z = fields["type"] == "frame" ? (@low -= 1) : (@high += 1)
    step(board.center(fields)) do
      board.create(key, fields, text, "z" => z, "ask" => @ask, "by" => "agent:#{@owner.id}")
    end
    select_too(key)
    key
  end

  def update_items(changes)
    changes = changes.first(MAX_PER_CALL).map { |change| change.to_h.transform_keys(&:to_s) }
    ids = changes.map { |change| change["id"].to_s }
    doing("#{moves_only?(changes) ? "Moving" : "Changing"} #{count(ids.size, "item")}",
          ids.select { |id| board.exists?(id) })
    changes.map { |change| update_one(change["id"].to_s, change) }.join("\n")
  end

  def moves_only?(changes) = changes.flat_map(&:keys).uniq.difference(%w[id x y]).empty?

  def update_one(key, change)
    item = board.item(key) or return "#{key}: no such item; look at the board again"
    fields, text = BoardSpec.update(item["type"], change, was: item["text"])
    return "#{key}: nothing to change" if fields.empty? && text.nil?

    step(board.center(item.merge(fields))) { keeping(key) { board.change(key, fields, text) } }
    "#{key}: changed#{collisions(key)}"
  rescue BoardSpec::Invalid => e
    "#{key}: skipped, #{e.message}"
  end

  def collisions(key) = board.overlap_note(key, view_of(asks.get_map(@ask)))

  def delete_items(ids)
    doing("Removing #{count(ids.size, "item")}", ids.map(&:to_s).select { |id| board.exists?(id) })
    ids.first(MAX_PER_CALL).map do |key|
      key = key.to_s
      item = board.item(key) or next "#{key}: no such item"
      gone = [key, *board.attached(key)]
      step(board.center(item)) do
        gone.each { |each_key| keeping(each_key) { board.delete(each_key) } }
      end
      "#{key}: deleted#{" with #{gone.size - 1} connector(s)" if gone.size > 1}"
    end.join("\n")
  end

  def set_title(title, subtitle = "")
    title, subtitle = [[title, 80], [subtitle, 140]].map { |words, max| words.to_s.gsub(/\s+/, " ").strip[0, max] }
    return "The title can't be empty." if title.empty?

    doing("Titling the board")
    view = view_of(asks.get_map(@ask))
    step([view[0] + 120, view[1] + 40]) do
      ask = asks.get_map(@ask)
      ask["titleBefore"] ||= JSON.generate(board.title_words)
      board.retitle(title, subtitle)
      ask["titleAfter"] = JSON.generate(board.title_words)
      ask["titled"] = true
    end
    "Title set."
  end

  # For the canned plan: whether the board has a title someone else set, and
  # a spot clear of what's there.
  def keep_title? = board.titled? && !asks.get_map(@ask)["titled"]
  def clear_spot = board.origin(@ask, asks.get_map(@ask).to_h.except("origin"))

  # What the ask being answered added, as ids.
  def own_items = board.added_by(@ask)

  private

  def board = BoardContents.new(doc)
end
