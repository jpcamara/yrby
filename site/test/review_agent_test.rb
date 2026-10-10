require "test_helper"

# What the demo agent writes, against a stand-in for Y::Agent that edits a
# real Y::Doc. test/agent_invite_test.rb covers the invitation.
class ReviewAgentTest < ActiveSupport::TestCase
  class FakeAgent
    attr_reader :doc, :presences

    def initialize
      @doc = Y::Doc.new
      @presences = []
    end

    def on_change(&block) = @on_change = block
    def change(blocks) = @on_change.call(blocks)
    def edit = @doc.diff { yield @doc }

    def presence=(state)
      @presences << state
    end
  end

  class FakeModel
    def review(_text) = %w[A short review.].each { |w| yield "#{w} " }
    def answer(question, _text) = yield("You asked: #{question}")
  end

  class DownModel
    def answer(...) = raise(AgentModel::Error, "the model timed out")
  end

  setup { @agent = FakeAgent.new }

  def blocks = (0...@agent.doc.get_xml_text("root").xml_text_count).map { |i| root.xml_text(i).text }
  def root = @agent.doc.get_xml_text("root")
  def person_writes(text) = Y::Lexxy.append_paragraph(@agent.doc, text)

  test "it says hello in an empty document and stops there" do
    ReviewAgent.new(@agent, model: FakeModel.new).start

    assert_equal [ReviewAgent::HELLO], blocks
  end

  test "it reviews what is already written, streaming it in" do
    person_writes("Launch plan for the November release.")
    ReviewAgent.new(@agent, model: FakeModel.new).start

    assert_equal ["Launch plan for the November release.", ReviewAgent::HELLO, "A short review. "], blocks
    assert(@agent.presences.any? { |p| p["anchorPos"] }, "the caret follows the writing")
    refute @agent.presences.last["focusing"]
  end

  test "it answers a question under the line that asked it, once" do
    ReviewAgent.new(@agent, model: FakeModel.new).start
    person_writes("@agent what is this?")
    @agent.change([1])
    @agent.change([1])

    assert_equal [ReviewAgent::HELLO, "@agent what is this?", "You asked: what is this?"], blocks
  end

  test "a question still being typed waits until it ends or the person moves on" do
    ReviewAgent.new(@agent, model: FakeModel.new).start
    person_writes("@agent summarize")
    @agent.change([1])

    assert_equal 2, blocks.size

    person_writes("")
    @agent.change([1, 2])

    assert_equal "You asked: summarize", blocks[2]
  end

  test "a model failure is said in the document" do
    ReviewAgent.new(@agent, model: DownModel.new).start
    person_writes("@agent are you there?")
    @agent.change([1])

    assert_equal "(The agent couldn't answer: the model timed out.)", blocks[2]
  end
end
