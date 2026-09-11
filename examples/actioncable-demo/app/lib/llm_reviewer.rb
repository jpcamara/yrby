# frozen_string_literal: true

# A review from a model through ruby_llm. Fireworks AI (OpenAI-compatible,
# FIREWORKS_API_KEY) or Anthropic (ANTHROPIC_API_KEY), whichever key is set;
# AGENT_MODEL overrides the model. Any failure falls back to the stub, so a
# bad key or a network blip never leaves the document without a review.
class LlmReviewer
  FIREWORKS_BASE = "https://api.fireworks.ai/inference/v1"
  FIREWORKS_MODEL = "accounts/fireworks/models/glm-5p3-flash"
  ANTHROPIC_MODEL = "claude-sonnet-5"

  PROMPT = <<~PROMPT
    You are reviewing a short working document that a team is editing together.
    Reply in plain text with no markdown headings: first one short paragraph
    summarizing what the document is and how it reads, then two or three
    concrete suggestions, each on its own line starting with "- ".

    Document:
    %s
  PROMPT

  QUESTION_PROMPT = <<~PROMPT
    You are a collaborator in a short working document that a team is editing
    together. Someone in the document asked you a question, marked with @agent.
    Answer it in plain text with no markdown headings: a short paragraph, then
    if useful two or three concrete points, each on its own line starting with "- ".

    Question:
    %s

    Document:
    %s
  PROMPT

  EDIT_PROMPT = <<~PROMPT
    You are editing a short working document that a team shares. The document
    is a list of numbered blocks. Apply this instruction: %s

    Reply with JSON only, no prose, no code fences: {"edits":[...]} where each
    edit is one of:
    {"op":"replace","block":N,"text":"new text for that block"}
    {"op":"insert_after","block":N,"text":"text for a new block after N"}
    {"op":"delete","block":N}
    {"op":"heading","block":N,"level":2}
    In insert_after text, start a line with "- " for a bullet or "1. " for a
    numbered item; several lines make several blocks. Refer to blocks by
    number. Keep edits minimal and concrete. At most 12 edits.

    Document:
    %s
  PROMPT

  # An edit plan for `instruction` over `blocks` (the document's top-level
  # blocks, in order). Falls back to the stub's plan.
  def edits(instruction, blocks)
    numbered = blocks.each_with_index.map { |b, i| "[#{i}] #{b}" }.join("\n")
    Reviewer.parse_edits(ask(format(EDIT_PROMPT, instruction.inspect, numbered)))
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.edits(instruction, blocks)
  end

  def self.available?
    !ENV["FIREWORKS_API_KEY"].to_s.empty? || !ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def call(text)
    Reviewer.parse(ask(format(PROMPT, text)))
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.call(text)
  end

  # Chunks as the model produces them. If the model fails before the first
  # chunk, the stub's stream takes over; a failure mid-stream ends it, since
  # a fixed review after real words would read as nonsense.
  def stream(text, &block)
    started = false
    streamed(format(PROMPT, text)) do |chunk|
      started = true
      block.call(chunk)
    end
  rescue StandardError => e
    raise if started

    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.stream(text, &block)
  end

  # An answer, streamed, with the same fallback rule.
  def answer(question, text, &block)
    started = false
    streamed(format(QUESTION_PROMPT, question, text)) do |chunk|
      started = true
      block.call(chunk)
    end
  rescue StandardError => e
    raise if started

    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.answer(question, text, &block)
  end

  private

  # Stream a prompt, skipping the chunks a reasoning model sends with no text.
  def streamed(prompt)
    chat.ask(prompt) do |chunk|
      content = chunk.content.to_s
      yield content unless content.empty?
    end
    nil
  end

  def ask(prompt)
    chat.ask(prompt).content.to_s
  end

  def chat
    require "ruby_llm"
    if ENV["FIREWORKS_API_KEY"].to_s.empty?
      RubyLLM.configure do |c|
        c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
        c.request_timeout = 90
      end
      RubyLLM.chat(model: ENV.fetch("AGENT_MODEL", ANTHROPIC_MODEL), provider: :anthropic, assume_model_exists: true)
    else
      RubyLLM.configure do |c|
        c.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
        c.openai_api_base = FIREWORKS_BASE
        c.request_timeout = 90
      end
      RubyLLM.chat(model: ENV.fetch("AGENT_MODEL", FIREWORKS_MODEL), provider: :openai, assume_model_exists: true)
    end
  end
end
