# The demo agent's model is on Fireworks AI, which speaks the OpenAI API, or
# on OpenAI itself when OPENAI_API_KEY is set (then AGENT_MODEL names the
# model, such as gpt-6.1-terra). Without either key, AgentModel streams a
# canned reply instead.
if %w[FIREWORKS_API_KEY OPENAI_API_KEY].any? { |key| ENV[key].present? } # AgentModel.live?
  require "ruby_llm"

  RubyLLM.configure do |config|
    if ENV["OPENAI_API_KEY"].present?
      config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
    else
      config.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
      config.openai_api_base = "https://api.fireworks.ai/inference/v1"
    end
    # A proposal takes a second or two; a stall should fail fast. A slower
    # model can raise it with AGENT_TIMEOUT.
    config.request_timeout = ENV.fetch("AGENT_TIMEOUT", 8).to_i
  end
end
