# What the board agent draws, from its model, as a plan BoardLayout reads.
# Like AgentModel, which it extends for the budget and the stall handling, it
# asks the agent's chat when FIREWORKS_API_KEY is set and streams a canned
# plan otherwise, so the demo draws something real without a key.
class BoardModel < AgentModel
  PROMPT = <<~TEXT.freeze
    Someone on a shared whiteboard asked you: %<prompt>s
    %<previous>s
    They're looking at the area from x=%<x>d, y=%<y>d to x=%<right>d, y=%<bottom>d.
    Board units: x grows to the right and y grows down.

    The board now:
    %<board>s

    Do what they asked with the tools. You choose every place and size.
    - Start in the area they're looking at when there's room, else beside
      what's there. Don't cover existing items unless they asked. Size a
      drawing like a slide, about 1400 wide and 800 tall, so it reads well
      when people zoom to fit.
    - A note with an icon or drawing is 180 by 200: the picture fills its
      top, with the title and caption under it. Without one it's 200 by 132. Leave about 40 between items so
      nothing touches.
    - To group items, draw a frame around them with a label. Frames always
      sit under other items.
    - Show flow or relationships with connectors (from and to are item ids,
      or refs you gave earlier in the same call).
    - Colors: yellow, blue, pink, green, purple, orange, or #rrggbb.
    - Draw in layers, one add_items call each, so people see it take shape
      right away: first the title and the main structure (a road, columns,
      or frames), then the labels on it, then the notes, then the
      illustrations and the finale.
    - The tools tell you when something overlaps another item. Fix real
      collisions once with update_items; leave small ones.
    - Move, resize, reword, or recolor with update_items; remove with
      delete_items. Look at the board again if people may have moved things.
    - Set the title with set_title only if the board has none or they asked.

    Make it look designed, the way a good facilitator draws:
    - Notes get a 2 to 4 word title, a caption with one concrete detail (a
      number, a name, a place), and an icon that pictures the step as a
      concrete object: 🫐 for a flavor, 🏷️ for pricing, 📈 for a forecast,
      🚚 for shipping, 🏪 for a store. Avoid abstract marks like ✅ or 📌.
    - Give every note and sticker a drawing too: a few words naming one
      concrete thing to draw for this subject ("a slice of huckleberry pie",
      "a pie box with a bow", "a delivery truck"), not an idea. An artist
      draws it in a shared style and it replaces the icon when it's ready.
    - Keep to one warm palette: notes in #fcd581 and #f9b872, with a green
      (#bbe5a7) only for the finale. No rainbow of note colors.
    - A timeline or process is a road: one thick path (stroke 16, color
      #f4a261) that climbs in a gentle wave from the lower left to the upper
      right, with 8 to 12 points and no sharp corners. It spans the whole
      slide, about 1300 wide, and rises only about 350 from end to end, so
      milestones sit 180 to 220 apart along it. Put a pill shape (#c4622d,
      about 76 by 30) on the road for each milestone ("Day 1", "Week 2"),
      centered on one of the path's points so it sits on the road. Each
      milestone's note goes above or below its pill, alternating sides,
      with about 50 clear between the note and the road, tied to the pill
      by a connector with arrow false and color #c4622d. Small text beside
      the road for gaps ("4 days on the road").
    - Illustrate: stickers (an emoji, 100 to 150 across) beside key moments,
      such as a truck on the road for shipping, and a short warning or aside
      as small text with ⚠️ where something could go wrong.
    - End a timeline or plan with a finale at the top of the road: a green
      frame holding a big sticker and a line or two about the outcome.
    - Group related notes in labeled frames when it helps reading.
    When you're done, reply with one short sentence saying what you did, such
    as "Laid out eight milestones from Day 1 to Day 12."
  TEXT

  PREVIOUS = <<~TEXT.freeze

    This is a change to an earlier ask of theirs, "%<earlier>s". Then you said:
    %<plan>s
    The items you added for it are marked "yours, from this ask". Change
    them, or the board, the way they ask now.
  TEXT

  def self.for(agent) = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new(agent) : new(agent)

  # Works the board for `prompt` through the agent's tools, and streams what
  # the model says when it's done. `board` is the agent's listing of the
  # board, `view` the [x, y, w, h] the person could see, and `previous` and
  # `earlier` what the agent said and was asked before, for a change.
  def draw(prompt:, board:, view:, previous: nil, earlier: nil, &)
    previous = earlier.to_s.empty? ? "" : format(PREVIOUS, earlier:, plan: previous.to_s.presence || "(nothing)")
    x, y, w, h = view
    stream(format(PROMPT, prompt:, previous:, board:, x:, y:, right: x + w, bottom: y + h), &)
  end

  # The stand-in without a key. It reads a subject, a start, and an end from
  # the ask ("... for the Huckleberry Pie launch, from locking the flavor to
  # holiday delivery") and lays out a twelve-day launch around them, one line
  # at a time, as a model streams.
  class Canned
    GROUPS = [
      ["Recipe", [["Day 1", nil, "Pick the recipe everyone loved", "🫐"],
                  ["Day 2", "Source ingredients", "Line up the farm and the mill", "🧺"],
                  ["Day 3", "Test bake", "Three batches, one winner", "🥧"]]],
      ["Business", [["Day 5", "Lock pricing", "Price per pie and per dozen", "🏷️"],
                    ["Day 6", "Build pre-order forecast", "Orders by week and by town", "📈"],
                    ["Day 8", "Design packaging", "A box that travels well", "📦"]]],
      ["Launch", [["Day 9", "Open pre-orders", "Announce it to the list", "📣"],
                  ["Day 10", "Bake and pack", "Ovens on at dawn", "👩‍🍳"],
                  ["Day 11", "Ship", "Out with the morning trucks", "🚚"]]]
    ].freeze

    def initialize(agent)
      @agent = agent
    end

    # Draws the canned timeline through the same writes the tools make. For a
    # change it takes away what it drew and draws it again.
    def draw(prompt:, view:, earlier: nil, **)
      @agent.delete_items(@agent.own_items) if earlier
      layout = BoardLayout.new(origin: @agent.clear_spot || view.first(2), titled: @agent.keep_title?)
      plan = plan_for(prompt, earlier:)
      plan.each { |line| layout.add(line).each { |item| put(item) } }
      layout.finish.each { |item| put(item) }
      yield "(No model key, so this is the canned plan.) Drew a timeline for #{JSON.parse(plan.first)["text"]}."
    end

    # The plan as JSON lines, for an ask and, on a change, the earlier ask.
    def plan_for(prompt, earlier: nil)
      subject, first, last = read(earlier ? "#{earlier} #{prompt}" : prompt)
      lines(subject, first, last, changed: earlier ? prompt : nil)
    end

    def put(item)
      if item.is_a?(BoardLayout::Title)
        @agent.set_title(item.text, item.subtitle)
      else
        @agent.add(item.fields.except("z"), item.text)
      end
    end

    private

    def lines(subject, first, last, changed:)
      subtitle = changed ? "Redrawn: #{changed}" : "A canned plan, since the demo has no model key"
      lines = [{ kind: "title", text: subject, subtitle: subtitle[0, 110] }]
      GROUPS.each do |group, steps|
        lines << { kind: "group", text: group }
        steps.each do |label, title, caption, icon|
          lines << { kind: "step", label:, title: title || first, caption:, icon: }
        end
      end
      lines << { kind: "finale", label: "Day 12", title: last, caption: "Everything lands on time", icon: "🎁" }
      lines.map { |line| JSON.generate(line) }
    end

    # "Lay out a timeline for the Huckleberry Pie launch, from locking the
    # flavor to holiday delivery" reads as "Huckleberry Pie launch", "Lock
    # flavor", and "Holiday delivery".
    def read(prompt)
      text = prompt.to_s.sub(/\A\s*@agent\b/i, "").strip
      span = text.match(/\bfrom\s+(.+?)\s+to\s+(.+?)[.!]*\z/i)
      subject = text[/\b(?:for|of|about)\s+(?:the\s+|a\s+|an\s+|our\s+)?(.+?)(?:,|\s+from\s|\z)/i, 1]
      subject = subject.presence || text.split(/[,.]/).first.to_s
      [sentence(subject[0, 50]), step_name(span&.[](1)) || "Kick off", sentence(span&.[](2)) || "Wrap up"]
    end

    # "locking the flavor" -> "Lock flavor"
    def step_name(phrase)
      return if phrase.blank?

      words = phrase.split.reject { |w| %w[the a an our].include?(w.downcase) }
      words[0] = words[0].downcase.sub(/(\w\w)ing\z/i, '\1').sub(/(\w)\1\z/, '\1') if words.first.length > 5
      sentence(words.first(4).join(" "))
    end

    def sentence(phrase) = phrase.presence && phrase.strip.sub(/\A\p{Ll}/, &:upcase)[0, 40]
  end
end
