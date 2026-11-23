require "y/agent"

# One person's agent on the agent sheet (/sheet). A person asks it for
# something in the side panel. The ask goes into the document's "asks" map, so
# everyone sees it, and this agent claims it. The model works the sheet
# through tools (SheetTools): it reads tabs, then writes, formats, and clears
# cells, sizes columns, and adds and renames tabs, deciding everything
# itself. The agent outlines each block before it writes it and moves its
# cell cursor to each cell, a moment apart, so people watch it work.
#
# Unlike PageAgent it writes the document itself, but it keeps everything it
# changed as it was before the ask, so anyone can undo the ask from its card.
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
#   previous, said   on an ask for a change: their earlier prompt, and what
#              the agent said when it answered it
#   createdAt  epoch milliseconds
#   status     "asked", then "working", then "done" or "failed". The browser
#              sets "stopped", "undone", or "asked" again.
#
# The agent writes startedAt, written (how many cells it changed), doing
# (what it's doing now, from its last tool call, such as "Reading
# Historical"), say (what the model said: while it works, the latest thing;
# once done, what it said after its last tool call), error, and what the
# ask's Undo needs:
#
#   before     Y.Map of "tabId!B4" => the cell as JSON before this ask first
#              changed it, or "" when it was empty. "tabId!width:B" holds a
#              column's width the same way.
#   after      the same keys => the cell as the ask last left it. Undo puts a
#              cell back only if it still looks like this, so later edits by
#              people stay.
#   addedTabs  JSON array of the ids of tabs it added; Undo removes them
#              once they're empty again
#   renamedTabs  JSON { tabId => [name before, name after] }
#
# A cell whose input the agent writes gets ask (the ask's id) and by (the
# agent's name).
class SheetAgent < Y::Agent
  include SheetWrites

  Owner = Data.define(:id, :name, :color)

  model ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast"), provider: :openai,
                                                                             assume_model_exists: true
  thinking effort: :low
  instructions <<~TEXT
    You are a careful analyst working in a shared spreadsheet that people are
    editing live, through tools. You decide what to build and where. People
    watch each cell land as you write it.
  TEXT

  PACE = 0.12 # seconds between changes, so people can follow the cursor
  SAY_EVERY = 0.4 # seconds between updates of what the model is saying
  MAX_FAILURES = 5 # failed tool calls per ask before it gives up

  def initialize(document, owner:, model: nil, pace: PACE, **)
    super(document, **)
    @owner = owner
    @pace = pace
    @model = model || SheetModel.for(self)
    self.presence = status("idle")
  end

  def name = "#{@owner.name}'s agent"

  def joined = answer_asks

  # Any change may be a new ask, or one asked again.
  def changed(_blocks) = answer_asks

  # Everyone but other agents, as in PageAgent.
  def people = super.reject { |_id, state| state["agent"] }

  def document_tools = SheetTools.all(self)

  # A tool call failed: tells the model why, so it can fix the call. After
  # MAX_FAILURES in one ask the ask fails, so a stuck model doesn't loop.
  def tool_failed(reason)
    @failures = @failures.to_i + 1
    raise AgentModel::Error, "its tool calls kept failing: #{reason}" if @failures >= MAX_FAILURES

    { error: reason }
  end

  def answer_asks
    waiting.each { |id, ask| answer(id, ask) }
  end

  private

  def waiting
    asks = sheet.asks
    mine = asks.keys.filter_map do |id|
      ask = asks.get_map(id)
      [id, ask] if ask && ask["owner"] == @owner.id && ask["status"] == "asked"
    end
    mine.sort_by { |_id, ask| ask["createdAt"].to_f }
  end

  def working?(id) = id && sheet.ask(id)&.[]("status") == "working"

  def answer(id, ask)
    started = epoch_ms
    @ask = id
    @tab = sheet.tab_ids.include?(ask["tab"]) ? ask["tab"] : sheet.tab_ids.first
    @cells = 0 # not @changes: Y::Collaborator keeps its update queue there
    @failures = 0
    @acted = false
    @reply = +""
    @shown = ""
    edit do
      sheet.update(id, "status" => "working", "startedAt" => started, "written" => 0, "error" => nil, "say" => nil,
                       "doing" => nil)
    end
    self.presence = status("working", started, id).merge("cell" => { "tab" => @tab, "ref" => ask["cell"] }.compact)
    work(id, ask)
  rescue AgentModel::Error => e
    edit { sheet.update(id, "status" => "failed", "error" => e.message, "doing" => nil) } if working?(id)
  rescue AgentModel::Stopped
    nil # people stopped or undid it; the ask already says so
  ensure
    @ask = nil
    self.presence = status("idle")
  end

  def work(id, ask)
    last = 0.0
    @model.work(prompt: ask["prompt"].to_s, asker: ask["askedBy"].to_s, tab: sheet.tab_name(@tab),
                selection: ask["cell"], sheet: sheet.overview, previous: ask["previous"], said: ask["said"]) do |chunk|
      @reply.clear if @acted # only what it says after its last tool call
      @acted = false
      @reply << chunk
      next unless monotonic - last > SAY_EVERY && working?(id)

      last = monotonic
      edit { sheet.update(id, **said) }
    end
    return unless working?(id)

    edit { sheet.update(id, "status" => "done", "say" => clean(@reply), "doing" => nil) }
  end

  # What the model has said since it last did something, when that's new.
  def said
    text = clean(@reply)
    return {} if text.empty? || text == @shown

    @shown = text
    { "say" => text }
  end

  def clean(text) = text.gsub(/\s+/, " ").strip[0, 600]

  # Its cell cursor goes to `ref` on tab `id`, with `range` outlined around
  # the block it's writing.
  def point(id, ref, range = nil)
    self.presence = presence.merge("cell" => { "tab" => id, "ref" => ref, "range" => range }.compact)
  end

  # The page draws the agent's cell cursor and range from "cell", in its
  # person's color, and labels it with user.name. "agent" says whose agent it
  # is, what it's doing, and which ask.
  def status(status, started = nil, ask = nil)
    {
      "user" => { "name" => name, "color" => @owner.color },
      "agent" => { "owner" => @owner.id, "ownerName" => @owner.name, "status" => status,
                   "startedAt" => started, "ask" => ask }.compact
    }
  end

  def epoch_ms = (Time.now.to_f * 1000).round
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
