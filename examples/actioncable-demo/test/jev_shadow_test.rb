# frozen_string_literal: true

require "minitest/autorun"
require "rails"
require "ruby_llm-typesafe"
require "stringio"
require_relative "../app/lib/jev_shadow"

class JevShadowTest < Minitest::Test
  class Wire < Faraday::Adapter
    class << self
      attr_accessor :requests, :response, :entered, :release
    end

    def call(env)
      super
      self.class.requests << { url: env.url.to_s, headers: env.request_headers, body: JSON.parse(env.body) }
      self.class.entered&.push(true)
      self.class.release&.pop
      status, body = self.class.response
      raise body if body.is_a?(Exception)

      save_response(env, status, JSON.generate(body), { "content-type" => "application/json" })
      @app.call(env)
    end
  end

  def setup
    @env = %w[TYPESAFE_API_KEY AGENT_JEV_MODEL].to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV["TYPESAFE_API_KEY"] = "private-test-key"
    ENV.delete("AGENT_JEV_MODEL")
    @config = RubyLLM.config.dup
    RubyLLM.configure { |c| c.faraday_adapter = Wire }
    @log = StringIO.new
    @shadow = JevShadow.new(enabled: true, logger: Logger.new(@log))
    Wire.requests = []
    Wire.entered = Wire.release = nil
    decision("leave_alone")
  end

  def teardown
    Wire.release&.push(true)
    @thread&.join(2)
    @env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    RubyLLM::Configuration.options.each { |k| RubyLLM.config.public_send("#{k}=", @config.public_send(k)) }
  end

  def decision(choice)
    Wire.response = [200, { model: "jev-1.13.0", answers: { intervention: {
      type: "choice", choice: choice, confidence: 0.96,
      probabilities: JevShadow::OPTIONS.to_h { |o| [o, o == choice ? 0.98 : 0.01] }
    } }, usage: { input_tokens: 100, output_tokens: 30 } }]
  end

  def snapshot
    @shadow.capture([1, 2], [2], ["Context", "Ada owns the rollout.", "Private draft", "Irrelevant"],
                    ["Already reviewed"])
  end

  def run_shadow(state = snapshot)
    @thread = @shadow.observe(state, llm_edits: 0, llm_ms: 720)

    assert @thread.join(2), "shadow request did not finish"
    events.last
  end

  def events
    @log.string.lines.map { |line| JSON.parse(line[line.index("{")..]) }
  end

  def test_real_provider_builds_structured_request_and_logs_no_text_or_credentials
    run_shadow
    request = Wire.requests.fetch(0)

    assert_equal "https://api.typesafe.ai/v1/systemone", request[:url]
    assert_equal "Bearer private-test-key", request[:headers]["Authorization"]
    assert_equal [1], request[:body].dig("state", "changed")
    assert_equal([0, 1, 2], request[:body].dig("state", "context").map { |b| b["id"] })
    assert request[:body].dig("state", "context", 2, "protected")
    assert_equal "choice", request[:body].dig("questions", "intervention", "type")
  end

  def test_log_records_decisions_and_timings_without_text_or_credentials
    event = run_shadow

    assert_equal "jev-1.13.0", event["model"]
    assert event["candidate_skip"]
    assert_equal 0, event["llm_edits"]
    assert_equal 100, event["input_tokens"]
    assert_equal 64, event["snapshot"].size
    %w[Ada Private private-test-key Already].each { |word| refute_includes @log.string, word }
    assert_equal @config.request_timeout, RubyLLM.config.request_timeout
    assert_equal @config.max_retries, RubyLLM.config.max_retries
  end

  def test_uncertain_or_positive_results_are_never_skip_candidates
    decision("insufficient_context")

    refute run_shadow["candidate_skip"]
    decision("consider")

    refute run_shadow["candidate_skip"]
    decision("leave_alone")
    Wire.response[1][:answers][:intervention][:probabilities] =
      { "leave_alone" => 0.6, "consider" => 0.3, "insufficient_context" => 0.1 }

    refute run_shadow["candidate_skip"]
  end

  def test_failures_are_observations_and_do_not_leak_provider_messages
    Wire.response = [401, { error: { message: "private-test-key Private draft" } }]

    assert_equal "error", run_shadow["status"]
    refute_includes @log.string, "private-test-key"
    refute_includes @log.string, "Private draft"
    Wire.response = [0, Faraday::TimeoutError.new("Private draft")]

    assert_equal "error", run_shadow["status"]
    assert_equal 2, Wire.requests.size, "shadow errors must not retry"
  end

  def test_no_key_disabled_protected_and_oversized_changes_do_not_call_model
    refute JevShadow.new(enabled: false).capture([0], [], ["hello"], [])
    ENV.delete("TYPESAFE_API_KEY")

    refute JevShadow.new(enabled: true).capture([0], [], ["hello"], [])
    refute @shadow.capture([0], [0], ["protected"], [])
    refute @shadow.capture([0], [], ["x" * JevShadow::MAX_BYTES], [])
    assert_empty Wire.requests
  end

  def test_only_one_request_can_be_in_flight_and_submission_does_not_wait
    Wire.entered = Queue.new
    Wire.release = Queue.new
    @thread = @shadow.observe(snapshot, llm_edits: 2, llm_ms: 100)

    assert Wire.entered.pop(timeout: 2)
    refute @shadow.observe(snapshot, llm_edits: 0, llm_ms: 200)
    assert_equal "busy", events.last["reason"]
    assert_equal 1, Wire.requests.size
    Wire.release.push(true)

    assert @thread.join(2)
    assert_equal 2, events.last["llm_edits"]
  end

  def test_invalid_probabilities_are_reported_without_becoming_a_skip_candidate
    Wire.response[1][:answers][:intervention][:probabilities]["leave_alone"] = 5
    event = run_shadow

    assert_equal "error", event["status"]
    refute event.key?("candidate_skip")
  end

  def test_snapshot_does_not_change_when_peer_memory_changes
    memory = ["Before"]
    state = @shadow.capture([0], [], ["hello"], memory)
    memory << "After"

    assert_equal ["Before"], JSON.parse(state)["recent_contributions"]
  end
end
