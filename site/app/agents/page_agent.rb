require "y/agent"

# One person's agent in a Lexxy room. A person asks it for a change by
# selecting text and saying what should change. The request goes into the
# document's "asks" map, so everyone in the room sees it. The agent claims it,
# covers the selected text with its own selection, and streams its proposed
# wording into the request. The page itself doesn't change until someone
# accepts the proposal, and their browser makes that edit like any other.
#
# An ask is a Y.Map the browser creates under a random id:
#
#   owner      the id of the person whose agent should answer
#   askedBy    that person's name
#   prompt     what they want changed
#   original   the selected text
#   paragraph  the paragraph around it, with the selection marked [[like this]]
#   previous   an earlier proposal, when the person asked for a change to it
#   from, to   Yjs relative positions of the selection
#   createdAt  epoch milliseconds
#   status     "asked", then "working", then "proposed" or "failed". The
#              browser sets "stopped", "accepted", "undone", or "asked" again.
#
# The agent writes startedAt (epoch milliseconds), proposal, and error.
class PageAgent < Y::Agent
  Owner = Data.define(:id, :name, :color)

  # Fireworks AI, configured in config/initializers/ruby_llm.rb. Low
  # reasoning effort answers in about a second.
  model ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast"), provider: :openai,
                                                                             assume_model_exists: true
  thinking effort: :low
  instructions <<~TEXT
    You are a helpful colleague inside a shared document that people are editing
    live. Write plain sentences with no markdown, no headings, and no preamble.
    Be brief and concrete.
  TEXT

  ASKS = "asks".freeze
  WRITE_EVERY = 0.2 # seconds between writes while a proposal streams in

  def initialize(document, owner:, model: nil, **)
    super(document, **)
    @owner = owner
    @model = model || AgentModel.for(self)
    self.presence = status("idle")
  end

  def name = "#{@owner.name}'s agent"

  # Asks made before the agent arrived are waiting for it.
  def joined = answer_asks

  # Any change may be a new ask, or one asked again.
  def changed(_blocks) = answer_asks

  # The model reads the page for context, and proposes. Only a person's
  # Accept changes the page.
  def document_tools = [Tools::ReadDocument.new(self)]

  # Answers every ask waiting for this agent, oldest first.
  def answer_asks
    waiting.each { |id, ask| answer(id, ask) }
  end

  private

  def asks = doc.get_map(ASKS)

  def waiting
    mine = asks.keys.filter_map do |id|
      ask = asks.get_map(id)
      [id, ask] if ask && ask["owner"] == @owner.id && ask["status"] == "asked"
    end
    mine.sort_by { |_id, ask| ask["createdAt"].to_f }
  end

  def answer(id, ask)
    started = epoch_ms
    edit { write(id, "status" => "working", "startedAt" => started, "proposal" => "", "error" => nil) }
    working(ask, started) do
      proposal = stream_proposal(id, ask)
      edit { write(id, "proposal" => proposal, "status" => "proposed") } if proposal
    end
  rescue AgentModel::Error => e
    edit { write(id, "status" => "failed", "error" => e.message) } if working?(id)
  end

  def working?(id) = asks.get_map(id)&.[]("status") == "working"

  # Streams the model's wording into the ask, a few words per write, and
  # returns all of it, or nil when someone stopped it. Stopping breaks out of
  # the model's stream, which closes the request.
  def stream_proposal(id, ask)
    proposal = +""
    written_at = 0
    stopped = false
    @model.rewrite(ask["paragraph"].presence || "[[#{ask["original"]}]]", ask["prompt"].to_s,
                   previous: ask["previous"]) do |chunk|
      unless working?(id)
        stopped = true
        break
      end

      proposal << chunk
      next if monotonic - written_at < WRITE_EVERY

      written_at = monotonic
      edit { write(id, "proposal" => one_paragraph(proposal)) }
    end
    one_paragraph(proposal).strip unless stopped
  end

  # A proposal replaces text inside one paragraph, so line breaks become
  # spaces.
  def one_paragraph(text) = text.gsub(/\s*\n+\s*/, " ")

  def write(id, fields)
    ask = asks.get_map(id) or return
    fields.each { |key, value| value.nil? ? ask.delete(key) : ask[key] = value }
  end

  # While the block runs, the agent's selection covers the text it's
  # rewriting, and its presence says it's working and since when. Every
  # editor in the room draws the selection, and the page shows the time.
  def working(ask, started)
    self.presence = status("working", started).merge("anchorPos" => ask["from"], "focusPos" => ask["to"],
                                                     "focusing" => true)
    yield
  ensure
    self.presence = status("idle")
  end

  # Lexical draws "name" on the caret. "agent" tells the page this peer is an
  # agent and whose it is.
  def status(status, started = nil)
    {
      "name" => name,
      "color" => @owner.color,
      "focusing" => false,
      "agent" => { "owner" => @owner.id, "ownerName" => @owner.name, "status" => status,
                   "startedAt" => started }.compact
    }
  end

  def epoch_ms = (Time.now.to_f * 1000).round

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
