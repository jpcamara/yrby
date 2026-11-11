require "y/agent"

# One person's agent on the agent sheet (/sheet). A person asks it for
# something in the side panel. The ask goes into the document's "asks" map, so
# everyone sees it, and this agent claims it, gives the model the sheet's
# inputs, and writes the cells the model streams back. Its cell cursor moves
# to each cell as it writes, so people watch it work.
#
# Unlike PageAgent it writes the document itself, but it keeps every cell's
# input from before the ask, so anyone can undo the ask from its card.
#
# The document (frontend/src/sheet.js has the browser's side):
#
#   tabs    Y.Array of tab ids, in order
#   sheets  Y.Map of tab id => Y.Map { name, cells, widths }
#           cells: "B4" => Y.Map { input, format, bold, fill, by, ask }
#           widths: column letter => pixels
#   asks    Y.Map of ask id => Y.Map, below
#
# An ask:
#
#   owner      the id of the person whose agent should answer
#   askedBy    that person's name
#   prompt     what they asked
#   tab        the id of the tab they were on
#   cell       the cell they had selected, such as "B4"
#   previous   their earlier prompt, when they asked for a change
#   createdAt  epoch milliseconds
#   status     "asked", then "working", then "done" or "failed". The browser
#              sets "stopped", "undone", or "asked" again.
#
# The agent writes startedAt, written (how many cells), say (its one-line
# summary), error, and before: a Y.Map of "tabId!B4" => the cell as it was
# before the ask first wrote it ({} when it was empty). A cell the agent writes
# gets ask (the ask's id) and by (the agent's name). Undo restores the cells
# whose ask is still this one.
class SheetAgent < Y::Agent
  Owner = Data.define(:id, :name, :color)

  model ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast"), provider: :openai,
                                                                             assume_model_exists: true
  thinking effort: :low
  instructions <<~TEXT
    You are a careful analyst working inside a shared spreadsheet that people
    are editing live. You answer only with the cell writes asked for.
  TEXT

  WRITE_GAP = 0.2 # seconds between cell writes, so people can follow the cursor
  MAX_WRITES = 200 # per ask

  def initialize(document, owner:, model: nil, **)
    super(document, **)
    @owner = owner
    @model = model || SheetModel.for(self)
    self.presence = status("idle")
  end

  def name = "#{@owner.name}'s agent"

  def joined = answer_asks

  # Any change may be a new ask, or one asked again.
  def changed(_blocks) = answer_asks

  # Everyone but other agents, as in PageAgent.
  def people = super.reject { |_id, state| state["agent"] }

  # The model gets the sheet in its prompt and answers with cell writes, so
  # it needs no tools.
  def document_tools = []

  def answer_asks
    waiting.each { |id, ask| answer(id, ask) }
  end

  private

  def sheet = SheetDocument.new(doc)

  def waiting
    asks = sheet.asks
    mine = asks.keys.filter_map do |id|
      ask = asks.get_map(id)
      [id, ask] if ask && ask["owner"] == @owner.id && ask["status"] == "asked"
    end
    mine.sort_by { |_id, ask| ask["createdAt"].to_f }
  end

  def working?(id) = sheet.ask(id)&.[]("status") == "working"

  def answer(id, ask)
    started = epoch_ms
    tab = ask["tab"].to_s
    edit { sheet.update(id, "status" => "working", "startedAt" => started, "error" => nil, "say" => nil) }
    self.presence = status("working", started).merge("cell" => { "tab" => tab, "ref" => ask["cell"] }.compact)
    written = write_from_model(id, ask, tab)
    edit { sheet.update(id, "status" => "done", "written" => written) } if written
  rescue AgentModel::Error => e
    edit { sheet.update(id, "status" => "failed", "error" => e.message) } if working?(id)
  ensure
    self.presence = status("idle")
  end

  # Writes each cell as the model's reply brings it, and returns how many it
  # wrote, or nil when someone stopped it. Returning from the block ends the
  # model's stream, which closes the request.
  def write_from_model(id, ask, tab)
    reader = SheetWrites.new
    count = 0
    @model.fill(sheet: sheet.listing, tab: sheet.tab_name(tab) || "Sheet1", prompt: ask["prompt"].to_s,
                asker: ask["askedBy"].to_s, selection: ask["cell"], previous: ask["previous"]) do |chunk|
      (reader << chunk).each do |item|
        return nil unless working?(id)

        count += take(id, item, tab, count)
      end
    end
    count
  end

  # Acts on one item of the reply, and returns how many cells it wrote.
  def take(id, item, tab, count)
    if item.is_a?(SheetWrites::Say)
      edit { sheet.update(id, "say" => item.text) }
      0
    elsif count < MAX_WRITES && write_cell(id, item, tab)
      1
    else
      0
    end
  end

  # Moves the agent's cursor to the cell, writes it, and pauses so people can
  # follow. Returns the tab it wrote to, or nil when the write names a tab
  # that doesn't exist.
  def write_cell(id, item, default_tab)
    tab = item.tab ? sheet.tab_named(item.tab) : default_tab
    return unless sheet.tab_ids.include?(tab)

    self.presence = presence.merge("cell" => { "tab" => tab, "ref" => item.cell })
    edit { sheet.write(id, tab, item, by: name) }
    sleep WRITE_GAP
    tab
  end

  # The page draws the agent's cell cursor from "cell", in its person's
  # color, and labels it with user.name. "agent" says whose agent it is and
  # what it's doing.
  def status(status, started = nil)
    {
      "user" => { "name" => name, "color" => @owner.color },
      "agent" => { "owner" => @owner.id, "ownerName" => @owner.name, "status" => status,
                   "startedAt" => started }.compact
    }
  end

  def epoch_ms = (Time.now.to_f * 1000).round
end
