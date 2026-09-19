# frozen_string_literal: true

require "minitest/autorun"
require "rails"
require "ruby_llm"
require_relative "../app/lib/review"
require_relative "../app/lib/reviewer"
require_relative "../app/lib/stub_reviewer"
require_relative "../app/lib/llm_reviewer"

# Exercise RubyLLM's real request builders and SSE parsers without API keys
# or network access. Only the HTTP adapter is replaced.
class LlmReviewerTest < Minitest::Test
  class Wire < Faraday::Adapter
    class << self
      attr_accessor :requests, :responses
    end

    def call(env)
      super
      self.class.requests << { url: env.url.to_s, headers: env.request_headers, body: JSON.parse(env.body) }
      response = self.class.responses.shift or raise "unexpected model request"
      status, chunks = response
      save_response(env, status, "", { "content-type" => "text/event-stream" })
      chunks.each do |chunk|
        raise chunk if chunk.is_a?(Exception)

        env.request.on_data.call(chunk, chunk.bytesize, env)
      end
      @app.call(env)
    end
  end

  ENV_KEYS = %w[AGENT_PROVIDER AGENT_MODEL FIREWORKS_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY TYPESAFE_API_KEY
                AGENT_JEV_SHADOW].freeze

  def setup
    @env = ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    @config = RubyLLM.config.dup
    @logger = Rails.logger
    Rails.logger = Logger.new(File::NULL)
    RubyLLM.configure do |config|
      config.faraday_adapter = Wire
      config.max_retries = 0
      config.openai_protocol = nil
    end
    Wire.requests = []
    Wire.responses = []
    @reviewer = LlmReviewer.new
  end

  def teardown
    @env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    RubyLLM::Configuration.options.each { |key| RubyLLM.config.public_send("#{key}=", @config.public_send(key)) }
    Rails.logger = @logger
  end

  def use_provider(provider)
    ENV["AGENT_PROVIDER"] = provider
    ENV["#{provider.upcase}_API_KEY"] = "test-key"
  end

  def event(data, type: nil)
    "#{"event: #{type}\n" if type}data: #{JSON.generate(data)}\n\n"
  end

  def completion(text, thinking: nil)
    chunks = []
    chunks << event({ choices: [{ delta: { reasoning: thinking } }] }) if thinking
    # Splitting an SSE event across reads catches accidental assumptions
    # that a network chunk always contains one complete model chunk.
    frame = event({ choices: [{ delta: { content: text } }] })
    chunks.push(frame[0, 17], frame[17..], "data: [DONE]\n\n")
    Wire.responses << [200, chunks]
  end

  def test_fireworks_stays_on_chat_completions_and_streams_thinking_separately
    use_provider("fireworks")
    completion("A useful review.", thinking: "Checking the plan.")
    thoughts = []
    @reviewer.on_thinking = thoughts.method(:<<)
    text = []
    @reviewer.stream("Our plan") { |chunk| text << chunk }
    request = Wire.requests.fetch(0)

    assert_equal "https://api.fireworks.ai/inference/v1/chat/completions", request[:url]
    assert_equal "Bearer test-key", request[:headers]["Authorization"]
    assert_equal LlmReviewer::FIREWORKS_MODEL, request[:body]["model"]
    assert_equal LlmReviewer::EFFORT, request[:body]["reasoning_effort"]
    assert request[:body]["stream"]
    assert_equal ["A useful review."], text
    assert_equal ["Checking the plan."], thoughts
  end

  def test_openrouter_keeps_its_provider_reasoning_format
    use_provider("openrouter")
    completion("A draft.", thinking: "Considering the section.")
    thoughts = []
    @reviewer.on_thinking = thoughts.method(:<<)
    text = []
    @reviewer.draft("Rollout", "Our plan") { |chunk| text << chunk }
    request = Wire.requests.fetch(0)

    assert_equal "https://openrouter.ai/api/v1/chat/completions", request[:url]
    assert_equal "Bearer test-key", request[:headers]["Authorization"]
    assert_equal LlmReviewer::OPENROUTER_MODEL, request[:body]["model"]
    assert_equal LlmReviewer::EFFORT, request[:body].dig("reasoning", "effort")
    assert_equal ["A draft."], text
    assert_equal ["Considering the section."], thoughts
  end

  def test_anthropic_streams_text_and_thinking_from_messages
    use_provider("anthropic")
    Wire.responses << [200, [
      event({ type: "message_start", message: { model: LlmReviewer::ANTHROPIC_MODEL, role: "assistant",
                                                content: [], usage: { input_tokens: 10, output_tokens: 0 } } },
            type: "message_start"),
      event({ type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "Checking." } },
            type: "content_block_delta"),
      event({ type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "An answer." } },
            type: "content_block_delta"),
      event({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 4 } },
            type: "message_delta"),
      event({ type: "message_stop" }, type: "message_stop")
    ]]
    thoughts = []
    @reviewer.on_thinking = thoughts.method(:<<)
    text = []
    @reviewer.answer("Why?", "Our plan") { |chunk| text << chunk }
    request = Wire.requests.fetch(0)

    assert_equal "https://api.anthropic.com/v1/messages", request[:url]
    assert_equal "test-key", request[:headers]["x-api-key"]
    assert_equal LlmReviewer::ANTHROPIC_MODEL, request[:body]["model"]
    assert_equal LlmReviewer::QUICK_EFFORT, request[:body].dig("output_config", "effort")
    assert_equal ["An answer."], text
    assert_equal ["Checking."], thoughts
  end

  def test_quick_model_override_uses_fireworks_chat_completions_too
    use_provider("fireworks")
    original = LlmReviewer::FAST_MODEL
    LlmReviewer.send(:remove_const, :FAST_MODEL)
    LlmReviewer.const_set(:FAST_MODEL, "accounts/fireworks/models/test-fast")
    completion("Yes.")

    @reviewer.answer("Ready?", "Our plan") { |chunk| assert_equal "Yes.", chunk }
    request = Wire.requests.fetch(0)

    assert_equal "https://api.fireworks.ai/inference/v1/chat/completions", request[:url]
    assert_equal "accounts/fireworks/models/test-fast", request[:body]["model"]
    assert_equal LlmReviewer::QUICK_EFFORT, request[:body]["reasoning_effort"]
  ensure
    LlmReviewer.send(:remove_const, :FAST_MODEL)
    LlmReviewer.const_set(:FAST_MODEL, original)
  end

  def test_review_parsing_and_memory_survive_the_upgrade
    use_provider("openrouter")
    ENV["AGENT_MODEL"] = "test/custom-model"
    completion("A rollout plan.\n- Name the owner.\n- Add a date.")
    review = @reviewer.call("Our plan")
    completion("You need an owner.")

    @reviewer.answer("What is missing?", "Our plan") { |chunk| assert_equal "You need an owner.", chunk }
    request = Wire.requests.last

    assert_equal "A rollout plan.", review.summary
    assert_equal ["Name the owner.", "Add a date."], review.suggestions
    assert_equal "test/custom-model", request[:body]["model"]
    assert_equal(%w[developer user], request[:body]["messages"].map { |message| message["role"] })
    assert_includes request[:body]["messages"].last["content"], "Reviewed the document: A rollout plan."
  end

  def test_json_edit_plans_remain_selection_scoped
    use_provider("openrouter")
    completion('{"edits":[{"op":"replace","block":0,"text":"Outside"},{"op":"replace","block":1,"text":"Inside"}]}')
    edits = @reviewer.edits("Shorten this", %w[First Second], only: 1..1)

    assert_equal [{ "op" => "replace", "block" => 1, "text" => "Inside" }], edits
  end

  def test_consideration_reads_json_text
    use_provider("openrouter")
    completion('{"note":"The owner is already named.","edits":[]}')
    result = @reviewer.consider([0], [], ["Ada owns the rollout."])

    assert_equal "The owner is already named.", result.note
    assert_empty result.edits
    assert_equal LlmReviewer::QUICK_EFFORT, Wire.requests.last[:body].dig("reasoning", "effort")
  end

  def test_shadow_observes_the_same_snapshot_without_changing_results_or_explicit_requests
    use_provider("openrouter")
    observations = []
    shadow = Object.new
    shadow.define_singleton_method(:capture) do |*args|
      observations << Marshal.load(Marshal.dump(args))
      "snapshot"
    end
    shadow.define_singleton_method(:observe) { |state, **baseline| observations << [state, baseline] }
    reviewer = LlmReviewer.new(shadow: shadow)
    reviewer.remember("Earlier contribution")
    completion('{"note":"Useful addition.","edits":[{"op":"insert_after","block":0,"text":"Name the owner."}]}')
    result = reviewer.consider([0], [], ["Launch tomorrow."])

    assert_equal "Name the owner.", result.edits.first["text"]
    assert_equal ["Earlier contribution"], observations.first.last
    assert_equal 1, observations.last.last[:llm_edits]
    completion("Sure.")

    reviewer.answer("Why?", "Launch tomorrow.") { |text| assert_equal "Sure.", text }
    assert_equal 2, observations.size, "explicit answers bypass shadow observation"
  end

  def test_shadow_records_a_failed_reviewer_without_swallowing_the_error
    use_provider("openrouter")
    observations = []
    shadow = Object.new
    shadow.define_singleton_method(:capture) { |*| "snapshot" }
    shadow.define_singleton_method(:observe) { |state, **baseline| observations << [state, baseline] }
    reviewer = LlmReviewer.new(shadow: shadow)
    Wire.responses << [401, [JSON.generate(error: { message: "Invalid key" })]]

    assert_raises(LlmReviewer::ModelError) { reviewer.consider([0], [], ["Launch tomorrow."]) }
    assert_equal "error", observations.last.last[:llm_status]
    assert_nil observations.last.last[:llm_edits]
  end

  def test_api_errors_remain_visible_instead_of_becoming_a_stub_review
    use_provider("openrouter")
    Wire.responses << [401, [JSON.generate(error: { message: "Invalid API key", code: 401 })]]

    error = assert_raises(LlmReviewer::ModelError) { @reviewer.call("Our plan") }

    assert_equal "the API key was rejected", error.message
    assert_empty @reviewer.memory_prompt
  end

  def test_failure_after_text_was_streamed_is_reported_without_replaying_the_text
    use_provider("fireworks")
    RubyLLM.config.max_retries = 3
    Wire.responses << [200, [event({ choices: [{ delta: { content: "Partial draft" } }] }),
                             Faraday::ConnectionFailed.new("connection closed")]]
    chunks = []

    error = assert_raises(LlmReviewer::ModelError) do
      @reviewer.draft("Rollout", "Our plan") { |chunk| chunks << chunk }
    end

    assert_equal "couldn't reach the model", error.message
    assert_equal ["Partial draft"], chunks
    assert_equal 1, Wire.requests.size
    assert_empty @reviewer.memory_prompt
  end

  def test_no_api_key_keeps_the_offline_demo_available
    assert_instance_of StubReviewer, Reviewer.default
    assert_empty Wire.requests
  end
end
