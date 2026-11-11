# What the board agent draws, from its model, as a plan BoardLayout reads.
# Like AgentModel, which it extends for the budget and the stall handling, it
# asks the agent's chat when FIREWORKS_API_KEY is set and streams a canned
# plan otherwise, so the demo draws something real without a key.
class BoardModel < AgentModel
  PLAN = <<~TEXT.freeze
    Someone on a shared whiteboard asked you: %<prompt>s
    %<previous>s
    The board has:
    %<board>s

    Reply with a plan for your drawing: one JSON object per line, in drawing
    order, and nothing else. No markdown, no code fences, no commentary. The
    kinds of line are:

    {"kind":"title","text":"A short title","subtitle":"One line about it"}
    {"kind":"group","text":"Phase name"}
    {"kind":"step","label":"Day 1","title":"Lock flavor","caption":"Pick the final recipe","icon":"🥧"}
    {"kind":"note","title":"Farmers market","caption":"Sample slices on Saturday","icon":"🧺"}
    {"kind":"finale","label":"Day 12","title":"Holiday delivery","caption":"Pies at every door","icon":"🎁"}

    Start with a title. For anything in order, such as a timeline, a plan,
    or a process, use only steps: give each a label (a day, week, or date),
    put them in 2 to 4 groups of 2 to 4 steps, and end with one finale,
    which is the last step, so don't write it as a step too. For ideas in no
    order, use only notes, in groups if that helps. Titles are 2 to 4 words
    and captions under 8 words. Each step, note, and finale has one emoji
    icon. Write 6 to 12 steps or notes. A step or note may add "color": one
    of yellow, blue, pink, green, purple, orange. The board places
    everything, so give no coordinates.
  TEXT

  PREVIOUS = <<~TEXT.freeze

    You already drew this for an earlier ask, "%<earlier>s":

    %<plan>s

    Write the whole plan again with their change. Your new drawing replaces
    the old one.
  TEXT

  def self.for(agent) = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new : new(agent)

  # Streams the plan for `prompt`. `board` describes what's on the board
  # already. `previous` is the plan this ask drew before, and `earlier` what
  # was asked then, when the person asked for a change to it.
  def plan(prompt, board:, previous: nil, earlier: nil, &)
    previous = previous.to_s.empty? ? "" : format(PREVIOUS, plan: previous, earlier:)
    stream(format(PLAN, prompt:, previous:, board: board.presence || "Nothing yet."), &)
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

    def plan(prompt, previous: nil, earlier: nil, **)
      subject, first, last = read(previous ? "#{earlier} #{prompt}" : prompt)
      lines(subject, first, last, changed: previous ? prompt : nil).each do |line|
        sleep 0.05
        yield "#{line}\n"
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
