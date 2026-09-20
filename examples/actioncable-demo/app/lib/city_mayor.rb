# frozen_string_literal: true

# The mayor: a model behind the planner, through ruby_llm, for the two things
# the rules cannot do. It reads a sign the rules do not understand ("trees
# please") as one of the instructions they do, and it names the streets and
# neighbourhoods as the town grows. Without a key there is no mayor and the
# planner works as before. A model that fails answers nil, and the planner
# leaves that question alone for a while.
#
# `ask:` takes a callable of one prompt returning the reply text, for tests
# and for other models; by default it is a fresh chat per call with the same
# provider the review agent uses (see LlmReviewer).
class CityMayor
  AUTHOR = "a:mayor"
  NAME_LENGTH = 24 # characters a name is cut to
  KINDS = { "street" => "a street", "district" => "a neighbourhood" }.freeze
  # The one-word answers a reading may start with.
  ANSWERS = { "PARK" => :park, "SHOP" => :shop, "ROAD" => :road, "BRIDGE" => :bridge, "NOBUILD" => :no_build,
              "NO BUILD" => :no_build, "CLEAR" => :clear, "NAME" => :name }.freeze
  INSTRUCTIONS = "You are the mayor of a small pixel-art town that people are building together. " \
                 "Answer with the words asked for and nothing else."

  # A mayor when the review agent's provider has a key, else nil.
  def self.default = defined?(LlmReviewer) && LlmReviewer.available? ? new : nil

  def initialize(ask: nil, logger: nil)
    @ask = ask || method(:model)
    @logger = logger || Logger.new($stderr)
  end

  # What a sign asks for, as one of City's instructions, :name for a sign
  # that asks for the street to be given a particular name, or nil when it
  # is only a sign or the model did not say. Only the first word of the
  # reply counts, so a model that explains itself after it does no harm.
  def read(text)
    reply = ask(<<~PROMPT)
      A sign in the town says: "#{text.to_s.strip[0, 80]}".
      Is it asking the town planner to build something there? If so, which of these is the closest:
      PARK, SHOP, ROAD, BRIDGE, NOBUILD (keep the area free of building), CLEAR (take out the roads, shops and parks near it).
      A sign that asks for the street or the place to be given a particular name, like "call this Ada Street", is NAME.
      A sign that only names a street or a place, like "Main Street" or "Old Town", asks for nothing.
      Reply with one word: PARK, SHOP, ROAD, BRIDGE, NOBUILD, CLEAR, NAME, or NONE.
    PROMPT
    words = reply.to_s.upcase.scan(/[A-Z]+/)
    ANSWERS[words.first(2).join(" ")] || ANSWERS[words.first.to_s]
  end

  # A name for a street or a neighbourhood, unlike the ones already taken.
  # `wishes:` are the texts of signs beside it; one that asks for a
  # particular name gets it. Nil when the model did not give one.
  def name(kind, taken: [], wishes: [])
    asked = wishes.first(5).map { |wish| "\"#{wish.to_s.strip[0, 60]}\"" }.join(", ")
    reply = ask(<<~PROMPT)
      Name #{KINDS.fetch(kind, kind)} in the town: two or three plain words, the kind of name a real town has.
      #{"Already taken: #{taken.first(20).join(", ")}." if taken.any?}
      #{"Signs beside it say: #{asked}. If one of them asks for a particular name, use that name." if wishes.any?}
      Reply with the name only.
    PROMPT
    name = reply.to_s.lines.first.to_s.gsub(/["'.!*_`]/, "").strip[0, NAME_LENGTH].strip
    name.empty? ? nil : name
  end

  private

  # One question, tried twice: a model call fails now and then for reasons
  # of its own, and a second fresh call is cheap.
  def ask(prompt, tries: 2)
    @ask.call(prompt)
  rescue StandardError => e
    @logger.warn("mayor: #{e.class}: #{e.message[0, 200]}")
    tries > 1 ? ask(prompt, tries: tries - 1) : nil
  end

  # One quick call, a fresh chat each time, on a context of the mayor's own:
  # the reasoning a model returns must not be sent back to it, and the
  # mayor's settings must not touch the reviewer's. Low reasoning effort is
  # the latency lever: about half a second a question against several.
  def model(prompt)
    context.chat(model: ENV.fetch("AGENT_MODEL", default_model), provider: ruby_llm_provider, assume_model_exists: true)
           .with_instructions(INSTRUCTIONS).with_thinking(effort: LlmReviewer::QUICK_EFFORT).ask(prompt).content.to_s
  end

  # The mayor asks again itself, so the client does not retry. Fireworks'
  # GLM chat template expects instructions in the system role; RubyLLM's
  # OpenAI provider sends the developer role unless told otherwise.
  def context
    require "ruby_llm"
    RubyLLM.context do |c|
      c.request_timeout = 30
      c.max_retries = 0
      case LlmReviewer.provider
      when :openrouter then c.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
      when :anthropic then c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
      else
        c.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
        c.openai_api_base = LlmReviewer::FIREWORKS_BASE
        c.openai_use_system_role = true
      end
    end
  end

  def ruby_llm_provider = LlmReviewer.provider == :fireworks ? :openai : LlmReviewer.provider

  def default_model
    case LlmReviewer.provider
    when :openrouter then LlmReviewer::OPENROUTER_MODEL
    when :anthropic then LlmReviewer::ANTHROPIC_MODEL
    else LlmReviewer::FIREWORKS_MODEL
    end
  end
end
