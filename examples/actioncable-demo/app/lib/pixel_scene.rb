# frozen_string_literal: true

# A small starting scene, stored once so everyone (including the Ruby peer)
# sees the same pixels. Human and artist changes live in separate overlay maps.
module PixelScene
  WIDTH = 64
  HEIGHT = 32
  BRIEF = "Build a playful pixel San Francisco together. Notice what people draw and add small details around their ideas."
  ANCHORS = "The starting scene has blue sky (color 13), a sun around (51,6), " \
            "the Golden Gate Bridge from x=6 to 41, y=13 to 27, " \
            "city buildings at x=44 to 62, y=15 to 27, and water below y=27. " \
            "These describe the starting scene only; people may have changed it. Read the current raster."
  LOCK = Mutex.new

  module_function

  def ensure(document_id)
    LOCK.synchronize do
      doc = Y::Doc.new
      (bytes = Store.current.replay(document_id)) && doc.apply_update(bytes)
      return unless JSON.parse(doc.read_map("scene") || "{}").empty?

      update = doc.diff do |d|
        map = d.get_map("scene")
        pixels.each { |key, color| map[key] = color }
        mural = d.get_map("mural")
        mural["brief"] = BRIEF unless mural.key?("brief")
        mural["enabled"] = false unless mural.key?("enabled")
      end
      Store.current.record(document_id, update)
      Y::ActionCable.broadcast(document_id, update)
    end
  end

  def pixels
    rows = Array.new(HEIGHT) { Array.new(WIDTH, 13) }
    box = lambda do |x, y, w, h, color|
      (y...[y + h, HEIGHT].min).each do |r|
        (x...[x + w, WIDTH].min).each { |c| rows[r][c] = color if r >= 0 && c >= 0 }
      end
    end
    # Sun and a pair of soft clouds.
    box.call(49, 3, 5, 7, 9)
    box.call(48, 4, 7, 5, 9)
    box.call(8, 5, 8, 2, 4)
    box.call(10, 4, 4, 1, 4)
    box.call(29, 8, 7, 2, 4)
    box.call(31, 7, 3, 1, 4)
    # Marin hillside and bay.
    box.call(0, 25, 64, 7, 12)
    10.times { |x| box.call(x, 23 - x / 3, 1, 5 + x / 3, 10) }
    # Skyline silhouettes with a few windows left for the artist.
    [[44, 19, 5, 9], [50, 15, 5, 13], [56, 21, 4, 7], [61, 18, 3, 10]].each do |x, y, w, h|
      box.call(x, y, w, h, 1)
      box.call(x, y, 1, h, 2)
    end
    box.call(52, 13, 1, 2, 1)
    [[46, 21], [46, 24], [52, 18], [52, 22], [58, 23], [62, 20]].each do |x, y|
      box.call(x, y, 1, 1, 8)
    end
    # Deck, piers, towers, and suspension cables.
    box.call(5, 23, 37, 2, 6)
    box.call(5, 23, 37, 1, 7)
    [12, 33].each do |x|
      box.call(x, 13, 2, 15, 6)
      box.call(x - 1, 14, 4, 1, 7)
      box.call(x - 1, 18, 4, 1, 7)
    end
    (5..41).each do |x|
      y = if x < 13
        14 + ((13 - x) * 0.8).round
      elsif x > 33
        14 + ((x - 33) * 0.8).round
      else
        14 + (6 * Math.sin(Math::PI * (x - 13) / 20)).round
      end
      rows[y][x] = 6
      box.call(x, y + 1, 1, 23 - y, 7) if (x % 4).zero?
    end
    [[6, 30, 6], [19, 28, 5], [29, 30, 7], [44, 29, 4], [55, 31, 5]].each do |x, y, w|
      box.call(x, y, w, 1, 13)
    end
    rows.each_with_index.each_with_object({}) do |(row, y), cells|
      row.each_with_index { |color, x| cells["#{x},#{y}"] = color }
    end
  end
end
