# frozen_string_literal: true

require "minitest/autorun"
require "ruby_llm"
require_relative "../app/lib/pixel_planner"

# Real RubyLLM 2 request construction and JSON parsing with only the HTTP
# transport replaced; no API key or network request is used by these tests.
class PixelPlannerTest < Minitest::Test
  class Wire < Faraday::Adapter
    class << self
      attr_accessor :requests, :reply, :finish_reason
    end

    def call(env)
      super
      self.class.requests << { url: env.url.to_s, body: JSON.parse(env.body), headers: env.request_headers }
      body = { id: "pixel-test", object: "chat.completion", model: "test/pixel-model",
               choices: [{ index: 0, message: { role: "assistant", content: self.class.reply }, finish_reason: self.class.finish_reason }],
               usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 } }
      save_response(env, 200, JSON.generate(body), { "content-type" => "application/json" })
      @app.call(env)
    end
  end

  ENV_KEYS = %w[AGENT_PROVIDER AGENT_MODEL AGENT_QUICK_REASONING PIXEL_MODEL PIXEL_REASONING FIREWORKS_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY].freeze

  def setup
    @env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    @config = RubyLLM.config.dup
    RubyLLM.configure do |config|
      config.faraday_adapter = Wire
      config.openai_api_base = "https://original.invalid/v1"
      config.openai_api_key = "original-key"
      config.openai_protocol = nil
      config.openai_use_system_role = false
    end
    Wire.requests = []
    Wire.finish_reason = "stop"
    Wire.reply = JSON.generate(note: "A warm reflection", pixels: [{ x: 2, y: 29, color: 8 }, { x: 3, y: 29, color: 9 }])
    @snapshot = PixelCanvas.new(scene: { "0,0" => 13 }, human: { "1,1" => 0 }, brief: "Warm reflections")
  end

  def teardown
    @env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    RubyLLM::Configuration.options.each { |key| RubyLLM.config.public_send("#{key}=", @config.public_send(key)) }
  end

  def test_fireworks_uses_isolated_chat_completions_configuration_and_actual_raster
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    ENV["AGENT_MODEL"] = "test/general-model"
    ENV["PIXEL_MODEL"] = "test/pixel-model"
    plan = PixelPlanner.new.call(@snapshot, changes: [{ "at" => "1,1", "from" => nil, "to" => 0 }])
    request = Wire.requests.fetch(0)
    assert_equal "https://api.fireworks.ai/inference/v1/chat/completions", request[:url]
    assert_equal "test/pixel-model", request[:body]["model"]
    assert_equal %w[system user], request[:body]["messages"].map { |message| message["role"] }
    assert_includes request[:body]["messages"].first["content"], "4-8 words"
    assert_equal "json_schema", request[:body].dig("response_format", "type")
    assert_equal true, request[:body].dig("response_format", "json_schema", "strict")
    assert_equal 96, request[:body].dig("response_format", "json_schema", "schema", "properties", "pixels", "maxItems")
    pixel_fields = request[:body].dig("response_format", "json_schema", "schema", "properties", "pixels", "items", "properties")
    assert_equal (0..63).to_a, pixel_fields.dig("x", "enum")
    assert_equal (0..31).to_a, pixel_fields.dig("y", "enum")
    assert_equal (0..15).to_a, pixel_fields.dig("color", "enum")
    assert_equal 8192, request[:body]["max_completion_tokens"]
    assert_equal 120, request[:body].dig("response_format", "json_schema", "schema", "properties", "note", "maxLength")
    assert_equal "low", request[:body]["reasoning_effort"], "unknown custom models keep a compatible low setting"
    assert_equal "Bearer test-fireworks-key", request[:headers]["Authorization"]
    assert_equal [[2, 29, 8], [3, 29, 9]], plan.pixels
    prompt = request[:body]["messages"].last["content"]
    assert_includes prompt, "Warm reflections"
    assert_includes prompt, "00: d#{'0' * 63}"
    assert_includes prompt, "01: .h#{'.' * 62}"
    assert_includes prompt, '"at":"1,1"'
    assert_equal "https://original.invalid/v1", RubyLLM.config.openai_api_base
    assert_equal "original-key", RubyLLM.config.openai_api_key
    assert_nil RubyLLM.config.openai_protocol
    refute RubyLLM.config.openai_use_system_role, "the Fireworks role override must remain isolated"
  end

  def test_fireworks_glm_uses_its_own_supported_low_default_and_can_be_overridden
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    ENV["AGENT_QUICK_REASONING"] = "high"
    PixelPlanner.new.call(@snapshot, changes: [])
    assert_equal "low", Wire.requests.last[:body]["reasoning_effort"]
    assert_equal 8192, Wire.requests.last[:body]["max_completion_tokens"]
    ENV["PIXEL_REASONING"] = "high"
    PixelPlanner.new.call(@snapshot, changes: [])
    assert_equal "high", Wire.requests.last[:body]["reasoning_effort"]
  end

  def test_openrouter_keeps_its_own_provider_and_model_default
    ENV["OPENROUTER_API_KEY"] = "test-openrouter-key"
    plan = PixelPlanner.new.call(@snapshot, changes: [])
    request = Wire.requests.fetch(0)
    assert_equal "https://openrouter.ai/api/v1/chat/completions", request[:url]
    assert_equal LlmReviewer::OPENROUTER_MODEL, request[:body]["model"]
    assert_equal "A warm reflection", plan.note
  end

  def test_no_key_is_a_visible_configuration_error_without_a_canned_plan
    refute PixelPlanner.available?
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "API_KEY"
    assert_empty Wire.requests
    ENV["AGENT_PROVIDER"] = "fireworks"
    refute PixelPlanner.available?, "naming a provider is insufficient without its API key"
  end

  def test_a_truncated_response_is_reported_even_if_it_contains_valid_json
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    Wire.finish_reason = "length"
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "cut short"
  end

  def test_invalid_pixel_objects_and_long_notes_are_rejected_as_a_whole
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    [{ x: 1, y: 1 }, { x: 1, y: 1, color: "9" }, { x: 1, y: 1, color: 9, extra: true }, [1, 1, 9]].each do |bad|
      Wire.reply = JSON.generate(note: "Invalid", pixels: [{ x: 2, y: 2, color: 8 }, bad])
      assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    end
    Wire.reply = JSON.generate(note: "x" * 121, pixels: [])
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "120 characters"
  end

  def test_caption_controls_are_normalized_without_rejecting_valid_paint
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    Wire.reply = JSON.generate(note: " Added\x7f  warm\nreflections\tto the bay.\x00 ",
                               pixels: [{ x: 2, y: 29, color: 8 }])
    plan = PixelPlanner.new.call(@snapshot, changes: [])
    assert_equal "Added warm reflections to the bay.", plan.note
    assert_equal [[2, 29, 8]], plan.pixels
    Wire.reply = JSON.generate(note: "\x7f" * 121, pixels: [])
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "120 characters", "length is checked before normalization"
    Wire.reply = JSON.generate(note: 123, pixels: [])
    assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
  end

  def test_malformed_model_output_is_reported_without_silently_dropping_bad_pixels
    ENV["FIREWORKS_API_KEY"] = "test-fireworks-key"
    Wire.reply = JSON.generate(note: "Invalid", pixels: [{ x: 1, y: 1, color: 9 }, { x: 64, y: 1, color: 9 }])
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "outside"
    Wire.reply = "Here is an idea without JSON"
    error = assert_raises(PixelPlanner::ModelError) { PixelPlanner.new.call(@snapshot, changes: []) }
    assert_includes error.message, "invalid JSON"
  end
end
