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

  INSTRUCTIONS = <<~TEXT.freeze
    You are a helpful colleague inside a shared document that people are editing
    live. Write plain sentences with no markdown, no headings, and no preamble.
    Be brief and concrete.
  TEXT

  REVIEW = <<~TEXT.freeze
    In two or three sentences, say what this document is for and one concrete
    way to make it better.

    Document:
    %s
  TEXT

  ANSWER = <<~TEXT.freeze
    Someone in the document asked: %s

    Answer in two or three sentences, from what the document says where it
    helps.

    Document:
    %s
  TEXT

  def self.default = ENV["FIREWORKS_API_KEY"].to_s.empty? ? Canned.new : new

  def initialize(seats: AgentSeats.current)
    @seats = seats
  end

  def review(text, &) = stream(format(REVIEW, text), &)

  def answer(question, text, &) = stream(format(ANSWER, question, text), &)

  private

  # Fireworks speaks the OpenAI API. A fresh chat per call: ruby_llm sends a
  # reasoning model's earlier reasoning back with the history, and Fireworks
  # rejects that. Low reasoning effort answers in about a second.
  def stream(prompt)
    raise Error, "the demo's model budget for today is used up" unless @seats.spend_call

    chat.with_thinking(effort: "low").ask(prompt) do |chunk|
      text = chunk.content.to_s
      yield text unless text.empty?
    end
  rescue Error
    raise
  rescue StandardError => e
    Rails.logger.warn("AgentModel: #{e.class}: #{e.message}")
    raise Error, describe(e)
  end

  def chat
    RubyLLM.configure do |c|
      c.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
      c.openai_api_base = FIREWORKS_BASE
      c.request_timeout = 60
    end
    RubyLLM.chat(model: MODEL, provider: :openai, assume_model_exists: true).with_instructions(INSTRUCTIONS)
  end

  def describe(error)
    case "#{error.class} #{error.message}"
    when /\b429\b|rate.?limit/i then "the model is rate limited; try again in a minute"
    when /timeout|timed out/i then "the model timed out"
    when /\b401\b|unauthor/i then "the model rejected the site's key"
    else "the model call failed"
    end
  end

  # The stand-in without a key. It streams word by word, as a model does.
  class Canned
    REPLY = "I'm the demo agent running without a model key, so this is a canned reply. " \
            "With a key I'd read the document and answer for real.".freeze

    def review(_text, &) = stream(&)
    def answer(_question, _text, &) = stream(&)

    private

    def stream
      REPLY.scan(/\S+\s*/).each do |word|
        sleep 0.05
        yield word
      end
    end
  end
end
