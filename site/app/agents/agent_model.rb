# What the demo agent says, from a model through ruby_llm. With
# FIREWORKS_API_KEY set it calls Fireworks AI. Without it (development, tests)
# it streams a fixed reply, so the demo runs without a key and without cost.
#
# Every call counts against AgentSeats' daily budget. A spent budget, and any
# model failure, raise AgentModel::Error with a short reason the agent writes
# into the document, so a failure is visible instead of passed off as an
# answer.
class AgentModel
  class Error < StandardError; end

  FIREWORKS_BASE = "https://api.fireworks.ai/inference/v1".freeze
  MODEL = ENV.fetch("AGENT_MODEL", "accounts/fireworks/routers/glm-5p3-fast")
  TIMEOUT = /timeout|timed out/i

  INSTRUCTIONS = <<~TEXT.freeze
    You are a helpful colleague inside a shared document that people are editing
    live. Write plain sentences with no markdown, no headings, and no preamble.
    Be brief and concrete.
  TEXT

  REWRITE = <<~TEXT.freeze
    Someone selected part of a paragraph in the document. Here is the
    paragraph, with the selection between [[ and ]]:

    %<paragraph>s

    They asked: %<prompt>s
    %<previous>s
    Reply with only the new text to put in place of the selection, so the
    paragraph still reads correctly around it. Keep the text outside the
    brackets out of your reply. One paragraph, no line breaks, no brackets,
    no quotes, no explanation.

    The whole document, for context:
    %<document>s
  TEXT

  PREVIOUS = <<~TEXT.freeze

    Your last proposal was:

    %s

    Change that proposal the way they asked.
  TEXT

  def self.default = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new : new

  def initialize(seats: AgentSeats.current)
    @seats = seats
  end

  # Streams the replacement for the selection marked [[like this]] in
  # `paragraph`, as `prompt` asks. `previous` is the agent's earlier proposal
  # when they asked for a change to it.
  def rewrite(paragraph, prompt, document, previous: nil, &)
    previous = previous.to_s.empty? ? "" : format(PREVIOUS, previous)
    stream(format(REWRITE, paragraph:, prompt:, previous:, document:), &)
  end

  private

  # Fireworks speaks the OpenAI API. A fresh chat per call: ruby_llm sends a
  # reasoning model's earlier reasoning back with the history, and Fireworks
  # rejects that. Low reasoning effort answers in about a second.
  #
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
    chat.with_thinking(effort: "low").ask(prompt) do |chunk|
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

  def chat
    RubyLLM.configure do |c|
      c.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
      c.openai_api_base = FIREWORKS_BASE
      c.request_timeout = 8 # a proposal takes a second or two; a stall should fail fast
    end
    RubyLLM.chat(model: MODEL, provider: :openai, assume_model_exists: true).with_instructions(INSTRUCTIONS)
  end

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
    def rewrite(paragraph, _prompt, _document, previous: nil)
      selection = previous.presence || paragraph[/\[\[(.*)\]\]/m, 1] || paragraph
      "(No model key, so here is your text back.) #{selection}".scan(/\S+\s*/).each do |word|
        sleep 0.05
        yield word
      end
    end
  end
end
