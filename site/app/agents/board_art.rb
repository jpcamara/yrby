require "nokogiri"

# Custom drawings for the board. The agent's model names a subject for a note
# or sticker ("a huckleberry pie"), and an artist asks the same model to draw
# it as SVG, in the background, while the agent keeps working. All drawings
# get one style prompt, so they look like a set.
#
# The model's SVG never reaches a page as markup. BoardArt.shapes keeps only
# plain shapes and the attributes that draw them, as data the page builds
# elements from (frontend/src/board.js, drawArt):
#
#   { "box" => [0, 0, 100, 100],
#     "shapes" => [["circle", { "cx" => "50", "cy" => "50", "r" => "40", "fill" => "#f4a261" }, []], ...] }
module BoardArt
  STYLE = <<~TEXT.freeze
    Draw %<subject>s as a flat illustration for a whiteboard sticker.
    Reply with only an <svg viewBox="0 0 100 100"> element, nothing else.
    Use path, circle, ellipse, rect, polygon, polyline, line, and g only, with
    attributes for color and stroke; no text, style, gradients, filters, or
    images. Style: bold simple shapes, a dark outline (#3b2a1a, stroke-width
    3, round joins) on the main shapes, warm flat colors, one lighter
    highlight shape, centered, filling about 80 percent of the box. 6 to 20
    elements.
  TEXT

  AGAIN = <<~TEXT.freeze
    That had no shapes I could use (%<reason>s). Send one <svg viewBox="0 0 100 100">
    with only path, circle, ellipse, rect, polygon, polyline, line, and g elements.
  TEXT

  TAGS = %w[g path circle ellipse rect polygon polyline line].freeze
  NUMBERS = /\A[-+0-9.,eE\s]{1,2000}\z/
  WORDS = /\A[a-z-]{1,12}\z/
  RULES = {
    "fill" => /\A(?:none|#\h{3}|#\h{6}|[a-zA-Z]{3,20})\z/,
    "stroke" => /\A(?:none|#\h{3}|#\h{6}|[a-zA-Z]{3,20})\z/,
    "d" => /\A[MmLlHhVvCcSsQqTtAaZz0-9eE.,+\-\s]{1,4000}\z/,
    "transform" => /\A(?:\s*(?:translate|scale|rotate|matrix|skewX|skewY)\([-+0-9.,eE\s]*\)\s*,?)+\z/,
    "stroke-linecap" => WORDS, "stroke-linejoin" => WORDS, "fill-rule" => WORDS
  }.merge(%w[cx cy r rx ry x y width height points x1 y1 x2 y2 stroke-width opacity fill-opacity
             stroke-opacity].index_with(NUMBERS)).freeze
  MAX_SHAPES = 200
  MAX_PER_ASK = 24

  module_function

  # The drawable part of the model's reply, as above, or nil with no shapes.
  def shapes(reply)
    root = Nokogiri::XML(reply.to_s[%r{<svg\b.*</svg>}m].to_s).root
    return unless root&.name == "svg"

    count = 0
    shapes = copy(root) { (count += 1) <= MAX_SHAPES }
    { "box" => box(root["viewBox"]), "shapes" => shapes } if count.positive?
  end

  def copy(node, &room)
    node.element_children.filter_map do |child|
      next unless TAGS.include?(child.name) && room.call

      [child.name, attributes(child), child.name == "g" ? copy(child, &room) : []]
    end
  end

  def attributes(node)
    node.attribute_nodes.to_h { |a| [a.name, a.value.strip] }.select { |name, value| RULES[name]&.match?(value) }
  end

  def box(view_box)
    numbers = view_box.to_s.split(/[\s,]+/).map { |each| Float(each, exception: false) }
    numbers.size == 4 && numbers.all? && numbers[2].positive? && numbers[3].positive? ? numbers : [0, 0, 100, 100]
  end

  # Draws in the background with the agent's model. Without a model key there
  # is no artist, and notes and stickers keep their emoji.
  def self.artist = ENV["FIREWORKS_API_KEY"].to_s.empty? ? nil : Artist.new

  class Artist
    def initialize(model: BoardAgent::MODEL, seats: AgentSeats.current)
      @model = model
      @seats = seats
    end

    # A thread whose value is the drawing of `subject`, or nil. Each drawing
    # counts against the day's model budget. A reply with nothing usable gets
    # one more try, told what was wrong.
    def start(subject)
      return unless @seats.spend_call

      Thread.new do
        chat = RubyLLM.chat(model: @model, provider: :openai, assume_model_exists: true).with_thinking(effort: :low)
        reply = chat.ask(format(STYLE, subject:)).content
        BoardArt.shapes(reply) || BoardArt.shapes(chat.ask(format(AGAIN, reason: why(reply))).content)
      rescue StandardError => e
        Rails.logger.warn("BoardArt #{subject.inspect}: #{e.class}: #{e.message}")
        nil
      end
    end

    private

    def why(reply)
      reply.to_s.include?("<svg") ? "only elements other than those" : "there was no <svg> element"
    end
  end
end
