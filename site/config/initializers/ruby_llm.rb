# The demo agent's model is on Fireworks AI, which speaks the OpenAI API.
# Without FIREWORKS_API_KEY, AgentModel streams a canned reply instead.
if ENV["FIREWORKS_API_KEY"].present?
  require "ruby_llm"

  RubyLLM.configure do |config|
    config.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
    config.openai_api_base = "https://api.fireworks.ai/inference/v1"
    config.request_timeout = 8 # a proposal takes a second or two; a stall should fail fast
  end
end
