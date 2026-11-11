require "y/agent"

# One person's agent on a board (/demos/board/:room). A person asks it to
# draw something. The ask goes into the board's "asks" map, so everyone sees
# it, and the agent claims it. The model writes a plan, one line per thing to
# draw, and BoardLayout places each line as it arrives. The agent writes each
# item onto the board itself, a moment apart, and moves its cursor to it, so
# everyone watches it draw. Every item it adds carries the ask's id, which is
# what the ask's Undo removes.
#
# The board document:
#
#   items     Y.Map of id -> Y.Map { type, x, y, w, h, z, color, text (Y.Text),
#             icon, points, from, to, by, ask }. frontend/src/board.js draws
#             them and has the full list of fields.
#   title     Y.Text, and subtitle, a Y.Text
#   asks      Y.Map of id -> Y.Map, below
#
# An ask is a Y.Map the browser creates:
#
#   owner      the id of the person whose agent should answer. Whoever asks
#              again (for a change, or after a failure) becomes the owner.
#   askedBy    that person's name
#   prompt     what they asked for
#   at         { x, y }: the top left of what they could see, where it draws
#   createdAt  epoch milliseconds
#   status     "asked", then "working", then "done" or "failed". The browser
#              sets "stopped", "undone", "dismissed", or "asked" again.
#   previous, earlier   on an ask for a change: the plan it drew and the
#              prompt it drew it for
#
# The agent writes startedAt, origin (where the drawing starts, so a redraw
# lands in the same place), plan, drawn (how many items), titled (it set the
# board's title), and error.
class BoardAgent < Y::Agent
  model ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast"), provider: :openai,
                                                                             assume_model_exists: true
  thinking effort: :low
  instructions <<~TEXT
    You draw on a shared whiteboard that people are editing live. You answer
    with a plan in JSON lines, exactly as asked, and nothing else.
  TEXT

  PACE = 0.3 # seconds between items, so people see it draw

  def initialize(document, owner:, model: nil, pace: PACE, **)
    super(document, **)
    @owner = owner
    @model = model || BoardModel.for(self)
    @pace = pace
    self.presence = status("idle")
  end

  def name = "#{@owner.name}'s agent"

  def joined = answer_asks

  def changed(_blocks) = answer_asks

  # Everyone but other agents, as on the Lexxy page (PageAgent#people).
  def people = super.reject { |_id, state| state["agent"] }

  # The board is in the prompt, and the agent writes what the model plans,
  # so the model gets no tools.
  def document_tools = []

  # Answers every ask waiting for this agent, oldest first.
  def answer_asks = waiting.each { |id, ask| answer(id, ask) }

  private

  def asks = doc.get_map("asks")
  def board = BoardContents.new(doc)

  def waiting
    asks.keys.map { |id| [id, asks.get_map(id)] }
        .select { |_id, ask| ask && ask["owner"] == @owner.id && ask["status"] == "asked" }
        .sort_by { |_id, ask| ask["createdAt"].to_f }
  end

  def answer(id, ask)
    started = epoch_ms
    origin = board.origin(id, ask)
    edit do
      board.remove(id) # an ask for a change redraws
      write(id, "status" => "working", "startedAt" => started, "origin" => { "x" => origin[0], "y" => origin[1] },
                "drawn" => 0, "error" => nil)
    end
    layout = BoardLayout.new(origin:, titled: board.titled? && !ask["titled"], above: board.top_z)
    working(id, started) { draw(id, ask, layout) }
  rescue AgentModel::Error => e
    edit { write(id, "status" => "failed", "error" => e.message) } if working?(id)
  end

  def draw(id, ask, layout)
    buffer = +""
    stopped = false
    @model.plan(ask["prompt"].to_s, board: board.summary(id), previous: ask["previous"],
                                    earlier: ask["earlier"]) do |chunk|
      buffer << chunk
      while (line = buffer.slice!(/\A[^\n]*\n/))
        stopped ||= !place(id, layout.add(line))
      end
      break if stopped
    end
    return unless !stopped && place(id, layout.add(buffer)) && place(id, layout.finish)

    edit { write(id, "status" => "done", "plan" => layout.lines.join("\n"), "drawn" => layout.count) }
  end

  # Writes each item, with the cursor on it first. False once the ask isn't
  # being worked on anymore, because someone stopped or undid it.
  def place(id, placed) # rubocop:disable Naming/PredicateMethod -- it draws, and says whether it could go on
    placed.each do |item|
      return false unless working?(id)

      point(item.at, id)
      edit { draw_item(id, item) }
      sleep @pace
    end
    true
  end

  # A title goes only on a board without one, or replaces the one this ask
  # set before.
  def draw_item(id, item)
    ask = asks.get_map(id)
    if item.is_a?(BoardLayout::Title)
      return if board.titled? && !ask["titled"]

      board.title(item)
      ask["titled"] = true
    else
      board.put(item, ask: id, by: "agent:#{@owner.id}")
      ask["drawn"] = ask["drawn"].to_i + 1
    end
  end

  def working?(id) = asks.get_map(id)&.[]("status") == "working"

  def write(id, fields)
    ask = asks.get_map(id) or return
    fields.each { |key, value| value.nil? ? ask.delete(key) : ask[key] = value }
  end

  # While it draws, its presence says so and since when, and which ask.
  def working(id, started)
    self.presence = status("working", started, id)
    yield
  ensure
    self.presence = status("idle").merge("cursor" => presence["cursor"]).compact
  end

  def point(at, id)
    self.presence = presence.merge("cursor" => { "x" => at[0], "y" => at[1] },
                                   "agent" => presence["agent"].merge("ask" => id))
  end

  # The page draws "user" like a person's, and "agent" says whose it is.
  def status(status, started = nil, ask = nil)
    {
      "user" => { "name" => name, "color" => @owner.color },
      "agent" => { "owner" => @owner.id, "ownerName" => @owner.name, "status" => status, "startedAt" => started,
                   "ask" => ask }.compact
    }
  end

  def epoch_ms = (Time.now.to_f * 1000).round
end
