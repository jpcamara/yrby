require "test_helper"

# How one person's agent answers asks, against a stand-in for Y::Agent that
# edits a real Y::Doc. test/agent_invite_test.rb covers the invitation.
class PageAgentTest < ActiveSupport::TestCase
  class FakeAgent
    attr_reader :doc, :presences

    def initialize
      @doc = Y::Doc.new
      @presences = []
    end

    def edit = @doc.diff { yield @doc }

    def presence=(state)
      @presences << state
    end
  end

  # Streams its words and records what it was asked.
  class FakeModel
    attr_reader :calls

    def initialize(*words, &during)
      @words = words.empty? ? ["We launch ", "in November."] : words
      @during = during
      @calls = []
    end

    def rewrite(paragraph, prompt, _document, previous: nil)
      @calls << { paragraph:, prompt:, previous: }
      @words.each_with_index do |word, i|
        @during&.call(i)
        yield word
      end
    end
  end

  class DownModel
    def rewrite(...) = raise(AgentModel::Error, "the model timed out")
  end

  ADA = PageAgent::Owner.new(id: "ada-0001", name: "Ada", color: "#f87171")
  BLOCK = { "client" => 1, "clock" => 0 }.freeze
  FROM = { "type" => BLOCK, "tname" => nil, "item" => { "client" => 1, "clock" => 3 }, "assoc" => 0 }.freeze
  TO = { "type" => BLOCK, "tname" => nil, "item" => { "client" => 1, "clock" => 9 }, "assoc" => 0 }.freeze

  setup { @agent = FakeAgent.new }

  def asks = @agent.doc.get_map("asks")
  def ask(id) = asks.get_map(id)

  def person_asks(id, owner: ADA.id, status: "asked", **fields)
    asks[id] = { "owner" => owner, "askedBy" => "Ada", "prompt" => "Make it shorter",
                 "original" => "Our launch is planned for November",
                 "paragraph" => "[[Our launch is planned for November]], if QA signs off.",
                 "from" => FROM, "to" => TO, "status" => status, "createdAt" => 1 }.merge(fields)
  end

  def agent_with(model) = PageAgent.new(@agent, owner: ADA, model:)

  test "it answers an ask for it with a proposal, and leaves the page alone" do
    person_asks("a1")
    model = FakeModel.new
    agent_with(model).answer_asks

    assert_equal "proposed", ask("a1")["status"]
    assert_equal "We launch in November.", ask("a1")["proposal"]
    assert ask("a1")["startedAt"]
    assert_equal "[[Our launch is planned for November]], if QA signs off.", model.calls.first[:paragraph]
    assert_equal "", @agent.doc.read_xml("root").to_s
  end

  test "while it works, its selection covers the asked-about text" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    working = @agent.presences.find { |p| p.dig("agent", "status") == "working" }

    assert_equal [FROM, TO], [working["anchorPos"], working["focusPos"]]
    assert working["focusing"]
    assert_equal "Ada's agent", working["name"]
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
    refute @agent.presences.last["focusing"]
  end

  test "it answers only its own person's open asks" do
    person_asks("mine")
    person_asks("theirs", owner: "linus-0002")
    person_asks("done", status: "accepted")
    agent_with(FakeModel.new).answer_asks

    assert_equal(%w[proposed asked accepted], %w[mine theirs done].map { |id| ask(id)["status"] })
  end

  test "a follow-up passes the last proposal back to the model" do
    person_asks("a1", previous: "We launch in November.", prompt: "Shorter still")
    model = FakeModel.new("November.")
    agent_with(model).answer_asks

    assert_equal "We launch in November.", model.calls.first[:previous]
    assert_equal "November.", ask("a1")["proposal"]
  end

  test "a proposal stays one paragraph" do
    person_asks("a1")
    agent_with(FakeModel.new("Announce it on the blog.\n", "\nBrief support.")).answer_asks

    assert_equal "Announce it on the blog. Brief support.", ask("a1")["proposal"]
  end

  test "stopping it mid-stream ends the stream and keeps it stopped" do
    person_asks("a1")
    model = FakeModel.new("We ", "launch ", "in ", "November.") do |i|
      asks.get_map("a1")["status"] = "stopped" if i == 2
    end
    agent_with(model).answer_asks

    assert_equal "stopped", ask("a1")["status"]
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "a model failure shows on the ask" do
    person_asks("a1")
    agent_with(DownModel.new).answer_asks

    assert_equal "failed", ask("a1")["status"]
    assert_equal "the model timed out", ask("a1")["error"]
  end
end
