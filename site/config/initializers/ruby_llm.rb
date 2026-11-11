# The demo agent's model is on Fireworks AI, which speaks the OpenAI API, or
# with LOCAL_MODEL_URL, a llama-server on this machine that speaks it too.
# Without either, AgentModel streams a canned reply instead.
if ENV["LOCAL_MODEL_URL"].present?
  require "ruby_llm"

  RubyLLM.configure do |config|
    config.openai_api_key = "local" # llama-server takes any key
    config.openai_api_base = ENV.fetch("LOCAL_MODEL_URL")
    config.request_timeout = 30 # one CPU thread; a second ask waits for the first
  end
elsif ENV["FIREWORKS_API_KEY"].present?
  require "ruby_llm"

  RubyLLM.configure do |config|
    config.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
    config.openai_api_base = "https://api.fireworks.ai/inference/v1"
    config.request_timeout = 8 # a proposal takes a second or two; a stall should fail fast
  end
end
