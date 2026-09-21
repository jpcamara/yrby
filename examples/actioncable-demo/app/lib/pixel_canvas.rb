# frozen_string_literal: true

require "digest"
require "json"

# An immutable, plain-Ruby view of the shared canvas. Human pixels are a
# separate overlay, including palette 0, so a delayed artist update can never
# win over a person's mark through CRDT last-writer ordering.
class PixelCanvas
  WIDTH = 64
  HEIGHT = 32
  MAX_PATCH = 96
  PALETTE = %w[#1d2038 #38415d #697a91 #b4c3ce #f6eedb #ffffff #c85b50 #f27c63
               #f6bb6a #ffe7a0 #447a70 #78b38b #36699b #66a4cc #9b78aa #d69bbd].freeze
  Plan = Data.define(:note, :pixels)
  class InvalidPlan < StandardError; end

  attr_reader :scene, :human, :artist, :brief, :signature

  def self.capture(doc)
    maps = %w[scene pixels artist_pixels mural].map { |name| JSON.parse(doc.read_map(name) || "{}") }
    new(scene: maps[0], human: maps[1], artist: maps[2], brief: maps[3]["brief"])
  end

  def initialize(scene: {}, human: {}, artist: {}, brief: "")
    @scene = valid_pixels(scene)
    @human = valid_pixels(human)
    @artist = valid_pixels(artist)
    @brief = brief.to_s[0, 240].freeze
    # Keep invalid input in the signature too: any human update invalidates
    # an inference, even though invalid values never reach the raster.
    @signature = Digest::SHA256.hexdigest(JSON.generate([human.sort, @brief])).freeze
    freeze
  end

  def self.key(x, y) = "#{x},#{y}"

  def self.coordinate?(key)
    return false unless key.is_a?(String) && key.match?(/\A(?:0|[1-9]\d*),(?:0|[1-9]\d*)\z/)

    x, y = key.split(",").map(&:to_i)
    x < WIDTH && y < HEIGHT
  end

  def self.color?(value) = value.is_a?(Integer) && value.between?(0, PALETTE.size - 1)

  # Reject an entire malformed response, not just its bad pixels. No
  # coercion: a float, string, extra-long patch, or off-canvas point is wrong.
  def self.plan(note:, pixels:)
    raise InvalidPlan, "the model's note must be a short line" unless note.is_a?(String) && note.length <= 240
    raise InvalidPlan, "the model must return at most #{MAX_PATCH} pixels" unless pixels.is_a?(Array) && pixels.size <= MAX_PATCH

    seen = {}
    clean = pixels.map do |point|
      unless point.is_a?(Array) && point.size == 3 && point.all? { |value| value.is_a?(Integer) }
        raise InvalidPlan, "each pixel must be [x, y, palette index]"
      end
      x, y, color = point
      unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1) && color?(color)
        raise InvalidPlan, "the model returned a pixel outside the canvas or palette"
      end
      key = key(x, y)
      raise InvalidPlan, "the model repeated a pixel" if seen[key]

      seen[key] = true
      point.dup.freeze
    end.freeze
    Plan.new(note: note.gsub(/[\p{Cc}\s]+/, " ").strip.freeze, pixels: clean)
  end

  def [](x, y)
    key = self.class.key(x, y)
    human.fetch(key) { artist.fetch(key) { scene.fetch(key, 0) } }
  end

  def rows
    HEIGHT.times.map { |y| WIDTH.times.map { |x| self[x, y].to_s(16) }.join }.freeze
  end

  def protected_rows
    HEIGHT.times.map do |y|
      WIDTH.times.map { |x| human.key?(self.class.key(x, y)) ? "h" : "." }.join
    end.freeze
  end

  def changes_since(previous)
    before = previous ? previous.human : {}
    (before.keys | human.keys).sort_by { |key| key.split(",").map(&:to_i).reverse }.filter_map do |key|
      next if before.key?(key) == human.key?(key) && before[key] == human[key]

      { "at" => key, "from" => before[key], "to" => human[key] }.freeze
    end.freeze
  end

  # Filter at the last possible snapshot, too. Protected points and pixels
  # which already have the requested effective color need no artist write.
  def writable(plan)
    plan.pixels.reject { |x, y, color| human.key?(self.class.key(x, y)) || self[x, y] == color }
  end

  private

  def valid_pixels(map)
    map.each_with_object({}) do |(key, value), result|
      result[key.dup.freeze] = value if self.class.coordinate?(key) && self.class.color?(value)
    end.freeze
  end
end
