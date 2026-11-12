require "json"
require "securerandom"
require "y/agent"

# One person's agent on a board (/demos/board/:room). A person asks it for
# something. The ask goes into the board's "asks" map, so everyone sees it,
# and the agent claims it. The model works the board through tools
# (BoardTools): it looks at what's there, then adds, changes, moves, connects,
# and deletes items, and sets the title, choosing every place and size
# itself. The agent makes each change a moment apart with its cursor on it,
# so everyone watches it work.
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
#   view       { x, y, w, h }: the part of the board they could see
#   at         { x, y }: the top left of that, from before `view`
#   createdAt  epoch milliseconds
#   status     "asked", then "working", then "done" or "failed". The browser
#              sets "stopped", "undone", "dismissed", or "asked" again.
#   previous, earlier   on an ask for a change: what the agent said it did,
#              and the prompt it did it for
#
# The agent writes startedAt, drawn (how many changes it made this time),
# plan (what it said it did), error, and what the ask's Undo needs:
#
#   before     Y.Map of item id -> the item as JSON before this ask first
#              changed or deleted it. Items the ask added carry `ask` instead.
#   after      Y.Map of item id -> the item as JSON after the ask's last
#              change to it, or "" once it deleted it. Undo restores an item
#              only if it still looks like this, so later edits by people stay.
#   titleBefore, titleAfter   the same for the title and subtitle, as JSON
#              [title, subtitle]
class BoardAgent < Y::Agent
  include BoardWrites
  include BoardSteps

  model ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast"), provider: :openai,
                                                                             assume_model_exists: true
  thinking effort: :low
  instructions <<~TEXT
    You work on a shared whiteboard that people are editing live, through
    tools. You decide what to draw, where, and how big. People watch each
    change land as you make it.
  TEXT

  PACE = 0.15 # seconds between changes, so people see it work
  VIEW = [1400, 900].freeze # the area to use when an ask has no view

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

  def document_tools = BoardTools.all(self)

  # Answers every ask waiting for this agent, oldest first.
  def answer_asks = waiting.each { |id, ask| answer(id, ask) }

  private

  def asks = doc.get_map("asks")

  def waiting
    asks.keys.map { |id| [id, asks.get_map(id)] }
        .select { |_id, ask| ask && ask["owner"] == @owner.id && ask["status"] == "asked" }
        .sort_by { |_id, ask| ask["createdAt"].to_f }
  end

  def answer(id, ask)
    started = epoch_ms
    @ask = id
    @steps = 0 # not @changes: Y::Collaborator keeps its update queue there
    @failures = 0
    @acted = false
    zs = board.items.to_h.values.filter_map { |item| item["z"] if item.is_a?(Hash) }
    @high = zs.max.to_i
    @low = zs.min.to_i
    edit do
      write(id, "status" => "working", "startedAt" => started, "drawn" => 0, "error" => nil)
      a = asks.get_map(id)
      a["before"] = {} unless a.get_map("before")
      a["after"] = {} unless a.get_map("after")
    end
    working(id, started) { work(id, ask) }
  rescue AgentModel::Error => e
    edit { write(id, "status" => "failed", "error" => e.message) } if working?(id)
  rescue AgentModel::Stopped
    nil # people stopped or undid it; the ask already says so
  ensure
    @ask = nil
  end

  def work(id, ask)
    reply = +""
    @model.draw(prompt: ask["prompt"].to_s, board: board.listing(id), view: view_of(ask),
                previous: ask["previous"], earlier: ask["earlier"]) do |chunk|
      reply.clear if @acted # only what it says after its last tool call
      @acted = false
      reply << chunk
    end
    return unless working?(id)

    said = reply.gsub(/\s+/, " ").strip[0, 600]
    edit { write(id, "status" => "done", "plan" => said, "activity" => nil) }
  end

  # The part of the board the asker could see, as [x, y, w, h].
  def view_of(ask)
    view = ask["view"]
    return view.values_at("x", "y", "w", "h").map(&:to_i) if view.is_a?(Hash) && view["w"].to_i.positive?

    at = ask["at"].is_a?(Hash) ? ask["at"].values_at("x", "y").map(&:to_i) : [0, 0]
    [*at, *VIEW]
  end

  def working?(id) = id && asks.get_map(id)&.[]("status") == "working"

  def write(id, fields)
    ask = asks.get_map(id) or return
    fields.each { |key, value| value.nil? ? ask.delete(key) : ask[key] = value }
  end

  # While it works, its presence says so and since when, and which ask.
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
