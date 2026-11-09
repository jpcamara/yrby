# What the demo agent says, from its model. With FIREWORKS_API_KEY set it asks
# the agent's own chat (see PageAgent). Without it (development, tests) it
# streams a fixed reply, so the demo runs without a key and without cost.
#
# Every call counts against AgentSeats' daily budget. A spent budget, and any
# model failure, raise AgentModel::Error with a short reason the agent writes
# into the document, so a failure is visible instead of passed off as an
# answer.
class AgentModel
  class Error < StandardError; end

  TIMEOUT = /timeout|timed out/i

  REWRITE = <<~TEXT.freeze
    Someone selected part of a paragraph in the document. Here is the
    paragraph, with the selection between [[ and ]]:

    %<paragraph>s

    They asked: %<prompt>s
    %<previous>s
    Reply with only the new text to put in place of the selection, so the
    paragraph still reads correctly around it. Keep the text outside the
    brackets out of your reply. One paragraph, no line breaks, no brackets,
    no quotes, no explanation. Call read_document first if the rest of the
    document would help.
  TEXT

  PREVIOUS = <<~TEXT.freeze

    Your last proposal was:

    %s

    Change that proposal the way they asked.
  TEXT

  def self.for(agent) = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new : new(agent)

  def initialize(agent, seats: AgentSeats.current)
    @agent = agent
    @seats = seats
  end

  # Streams the replacement for the selection marked [[like this]] in
  # `paragraph`, as `prompt` asks. `previous` is the agent's earlier proposal
  # when they asked for a change to it.
  def rewrite(paragraph, prompt, previous: nil, &)
    previous = previous.to_s.empty? ? "" : format(PREVIOUS, previous)
    stream(format(REWRITE, paragraph:, prompt:, previous:), &)
  end

  private

  # A call that stalls before any words arrive is tried once more. Once words
  # have arrived, people are watching the proposal, so a stall fails instead
  # of starting it over.
  def stream(prompt, &)
    raise Error, "the demo's model budget for today is used up" unless @seats.spend_call

    stalled = ask(prompt, again: true, &) == :stalled
    ask(prompt, again: false, &) if stalled
  rescue Error
    raise
  rescue StandardError => e
    Rails.logger.warn("AgentModel: #{e.class}: #{e.message}")
    raise Error, describe(e)
  end

  # Streams one call. With `again`, a timeout before any words returns
  # :stalled instead of raising.
  def ask(prompt, again:)
    streamed = false
    chat.ask(prompt) do |chunk|
      text = chunk.content.to_s
      next if text.empty?

      streamed = true
      yield text
    end
  rescue StandardError => e
    raise if streamed || !again || !"#{e.class} #{e.message}".match?(TIMEOUT)

    Rails.logger.warn("AgentModel: #{e.class}: #{e.message}; trying once more")
    :stalled
  end

  # A fresh chat per call, from the agent: its model, its instructions, and
  # read_document.
  def chat = @agent.chat

  def describe(error)
    case "#{error.class} #{error.message}"
    when /\b429\b|rate.?limit/i then "the model is rate limited; try again in a minute"
    when TIMEOUT then "the model timed out"
    when /\b401\b|unauthor/i then "the model rejected the site's key"
    else "the model call failed"
    end
  end

  # The stand-in without a key. It streams word by word, as a model does, and
  # says it's canned.
  class Canned
    def rewrite(paragraph, _prompt, previous: nil)
      selection = previous.presence || paragraph[/\[\[(.*)\]\]/m, 1] || paragraph
      "(No model key, so here is your text back.) #{selection}".scan(/\S+\s*/).each do |word|
        sleep 0.05
        yield word
      end
    end
  end
end
