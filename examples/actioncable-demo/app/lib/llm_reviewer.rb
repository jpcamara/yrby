# frozen_string_literal: true

# A review from a Claude model through ruby_llm. Any failure falls back to the
# stub, so a bad key or a network blip never leaves the document without a
# review.
class LlmReviewer
  MODEL = ENV.fetch("AGENT_MODEL", "claude-sonnet-5")
  PROMPT = <<~PROMPT
    You are reviewing a short working document that a team is editing together.
    Reply in plain text with no markdown headings: first one short paragraph
    summarizing what the document is and how it reads, then two or three
    concrete suggestions, each on its own line starting with "- ".

    Document:
    %s
  PROMPT

  def call(text)
    Reviewer.parse(ask(text))
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.call(text)
  end

  # Chunks as the model produces them. If the model fails before the first
  # chunk, the stub's stream takes over; a failure mid-stream ends it.
  def stream(text, &block)
    started = false
    ask(text) do |chunk|
      started = true
      block.call(chunk)
    end
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    raise if started

    StubReviewer.new.stream(text, &block)
  end

  private

  def ask(text, &)
    require "ruby_llm"
    RubyLLM.configure do |c|
      c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
      c.request_timeout = 60
    end
    chat = RubyLLM.chat(model: MODEL, provider: :anthropic, assume_model_exists: true)
    if block_given?
      chat.ask(format(PROMPT, text)) { |chunk| yield chunk.content.to_s }
      nil
    else
      chat.ask(format(PROMPT, text)).content
    end
  end
end
