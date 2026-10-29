require "test_helper"

# How AgentModel handles a model that stalls, against scripted chats instead
# of Fireworks. Each call to the model takes the next script: words to
# stream, then :stall to time out or :fail to raise another error.
class AgentModelTest < ActiveSupport::TestCase
  Chunk = Data.define(:content)

  class ScriptedChat
    def initialize(script) = @script = script
    def with_thinking(**) = self

    def ask(_prompt)
      @script.each do |step|
        case step
        when :stall then raise Faraday::TimeoutError, "Net::ReadTimeout"
        when :fail then raise Faraday::ConnectionFailed, "connection refused"
        else yield Chunk.new(step)
        end
      end
    end
  end

  class ScriptedModel < AgentModel
    attr_reader :calls

    def initialize(*scripts)
      super(seats: AgentSeats.new)
      @scripts = scripts
      @calls = 0
    end

    private

    def chat
      @calls += 1
      ScriptedChat.new(@scripts.shift)
    end
  end

  def rewrite(model)
    words = []
    model.rewrite("[[Our launch]] is soon.", "Shorter", "") { |text| words << text }
    words.join
  end

  test "a stall before any words is tried once more" do
    model = ScriptedModel.new([:stall], ["We ", "launch."])

    assert_equal "We launch.", rewrite(model)
    assert_equal 2, model.calls
  end

  test "a second stall fails" do
    model = ScriptedModel.new([:stall], [:stall])

    error = assert_raises(AgentModel::Error) { rewrite(model) }
    assert_equal "the model timed out", error.message
    assert_equal 2, model.calls
  end

  test "a stall after words have arrived fails without starting over" do
    model = ScriptedModel.new(["We ", :stall], ["We ", "launch."])

    error = assert_raises(AgentModel::Error) { rewrite(model) }
    assert_equal "the model timed out", error.message
    assert_equal 1, model.calls
  end

  test "other failures aren't tried again" do
    model = ScriptedModel.new([:fail], ["We ", "launch."])

    error = assert_raises(AgentModel::Error) { rewrite(model) }
    assert_equal "the model call failed", error.message
    assert_equal 1, model.calls
  end
end
