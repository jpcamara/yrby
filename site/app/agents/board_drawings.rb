# How a board agent puts custom drawings on its notes and stickers. When the
# model gives an item a `drawing`, the artist (BoardArt::Artist) starts on it
# in the background and the item shows its emoji meanwhile. Each finished
# drawing lands as its own change, with the cursor on the item, before the
# agent's next tool call and while it finishes the ask. BoardAgent includes
# it, for the ask it's answering (@ask, @drawings, and @sketches, how many
# it started). The art is stored as a JSON string: a Ruby hash would land as
# a Y.Map.
module BoardDrawings
  WAIT = 45 # seconds an ask waits at the end for drawings still coming

  # Starts drawing `subject` for the item `key`, if there's an artist.
  def draw_later(key, subject)
    return unless @artist && subject && (@sketches += 1) <= BoardArt::MAX_PER_ASK

    @drawings[key] = @artist.start(subject)
  end

  # Puts every finished drawing on its item.
  def place_drawings
    @drawings.reject { |_key, job| job&.alive? }.each_key { |key| place(key, @drawings.delete(key)&.value) }
  rescue BoardSpec::Invalid
    @drawings.clear # out of changes for this ask
  end

  private

  def no_drawings
    @drawings = {}
    @sketches = 0
  end

  def place(key, art)
    item = art && board.item(key)
    step(board.center(item)) { board.change(key, { "art" => JSON.generate(art) }, nil) } if item
  end

  # Waits for the drawings still coming, up to WAIT, placing each as it lands.
  def finish_drawings
    return if @drawings.empty?

    doing("Finishing #{count(@drawings.size, "drawing")}", @drawings.keys)
    deadline = Time.now + WAIT
    until @drawings.empty? || Time.now > deadline
      place_drawings
      sleep 0.2 unless @drawings.empty?
    end
    no_drawings
  end
end
