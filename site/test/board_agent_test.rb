require "test_helper"

# How one person's agent answers asks on a board, on a real Y::Doc without
# joining a room. test/boards_test.rb covers the page and the invitation.
class BoardAgentTest < ActiveSupport::TestCase
  # A BoardAgent that edits `doc` directly, records its presence, and draws
  # without pausing.
  class OfflineBoardAgent < BoardAgent
    Document = Data.define(:key, :name, :channel)

    attr_reader :doc, :presences

    def initialize(doc, **)
      @presences = []
      super(Document.new(key: "room/1/board", name: "board", channel: "BoardChannel"), url: "ws://unused", lock: nil,
                                                                                       pace: 0, **)
      @doc = doc
    end

    def edit = @doc.edit { yield @doc }

    def presence=(state)
      @presences << state
      @presence = state
    end
  end

  # Streams a plan in uneven chunks, as a model does, and records what it
  # was asked. `during` runs before each chunk.
  class FakeModel
    attr_reader :calls

    PLAN = [
      { kind: "title", text: "Pie launch", subtitle: "Twelve days" },
      { kind: "group", text: "Recipe" },
      { kind: "step", label: "Day 1", title: "Lock flavor", caption: "Pick it", icon: "🥧" },
      { kind: "step", label: "Day 2", title: "Lock pricing", caption: "Per pie", icon: "🏷️" },
      { kind: "finale", label: "Day 12", title: "Holiday delivery", caption: "At every door", icon: "🎁" }
    ].map { |line| JSON.generate(line) }.join("\n")

    def initialize(plan = PLAN, &during)
      @plan = plan
      @during = during
      @calls = []
    end

    def plan(prompt, board:, previous: nil, earlier: nil)
      @calls << { prompt:, board:, previous:, earlier: }
      @plan.scan(/.{1,17}/m).each_with_index do |chunk, i|
        @during&.call(i)
        yield chunk
      end
    end
  end

  class DownModel
    def plan(...) = raise(AgentModel::Error, "the model timed out")
  end

  ADA = PageAgent::Owner.new(id: "ada-0001", name: "Ada", color: "#f87171")

  setup { @doc = Y::Doc.new }

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def items = JSON.parse(@doc.read_map("items"))
  def drawn(id) = items.values.select { |item| item["ask"] == id }

  def person_asks(id, owner: ADA.id, status: "asked", **fields)
    asks[id] = { "owner" => owner, "askedBy" => "Ada", "prompt" => "Lay out a timeline for the pie launch",
                 "at" => { "x" => 40, "y" => 60 }, "status" => status, "createdAt" => 1 }.merge(fields)
  end

  def agent_with(model) = @agent = OfflineBoardAgent.new(@doc, owner: ADA, model:)

  test "it draws the plan on the board, every item marked with the ask" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    assert_equal "done", ask("a1")["status"]
    kinds = drawn("a1").map { |item| item["type"] }.tally

    assert_equal({ "shape" => 3, "note" => 2, "path" => 2, "frame" => 2, "sticker" => 1, "text" => 1 }, kinds)
    assert_equal drawn("a1").size, ask("a1")["drawn"]
    assert(drawn("a1").all? { |item| item["by"] == "agent:ada-0001" })
    assert_includes drawn("a1").map { |item| item["text"] }, "Lock flavor\nPick it"
  end

  test "an empty board gets the plan's title, and the ask remembers it set it" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    assert_equal "Pie launch", @doc.read_text("title")
    assert_equal "Twelve days", @doc.read_text("subtitle")
    assert ask("a1")["titled"]
  end

  test "a board with a title keeps it, and the drawing gets a heading" do
    @doc.get_text("title").push("Our board")
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    assert_equal "Our board", @doc.read_text("title")
    assert_includes drawn("a1").map { |item| item["text"] }, "Pie launch"
    refute ask("a1")["titled"]
  end

  test "it draws where the person was looking, from the top left of the plan" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    assert_equal({ "x" => 40, "y" => 60 }, ask("a1")["origin"])
    assert(drawn("a1").all? { |item| item["x"] >= 0 && item["y"] >= 60 })
  end

  test "it keeps clear of what's on the board already" do
    @doc.get_map("items")["mine"] = { "type" => "note", "x" => 100, "y" => 100, "w" => 200, "h" => 900, "z" => 4 }
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    assert_equal({ "x" => 100, "y" => 1160 }, ask("a1")["origin"])
    assert(drawn("a1").all? { |item| item["z"] > 4 || item["type"].in?(%w[path frame]) })
  end

  test "its cursor goes to each item as it draws it" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks

    cursors = @agent.presences.filter_map { |p| p["cursor"] }.uniq

    assert_operator cursors.size, :>=, drawn("a1").size - 2
    working = @agent.presences.find { |p| p.dig("agent", "status") == "working" }

    assert_equal "a1", working.dig("agent", "ask")
    assert_equal "Ada's agent", working.dig("user", "name")
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "it answers only its own person's open asks, oldest first" do
    person_asks("mine")
    person_asks("theirs", owner: "linus-0002")
    person_asks("undone", status: "undone")
    agent_with(FakeModel.new).answer_asks

    assert_equal(%w[done asked undone], %w[mine theirs undone].map { |id| ask(id)["status"] })
    assert_empty drawn("theirs")
  end

  test "stopping it mid-plan keeps what it drew and draws no more" do
    person_asks("a1")
    model = FakeModel.new { |i| asks.get_map("a1")["status"] = "stopped" if i == 14 }
    agent_with(model).answer_asks

    assert_equal "stopped", ask("a1")["status"]
    assert_operator drawn("a1").size, :>, 0
    assert_operator drawn("a1").size, :<, 11
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "an ask for a change redraws in the same place, with the old plan for the model" do
    person_asks("a1")
    agent_with(FakeModel.new).answer_asks
    first = drawn("a1").map { |item| item.values_at("x", "y") }
    plan = ask("a1")["plan"]

    ask("a1").then do |a|
      a["earlier"] = a["prompt"]
      a["previous"] = plan
      a["prompt"] = "Fewer steps"
      a["status"] = "asked"
    end
    model = FakeModel.new
    agent_with(model).answer_asks

    assert_equal "Fewer steps", model.calls.first[:prompt]
    assert_equal plan, model.calls.first[:previous]
    assert_includes plan, "Lock flavor"
    assert_equal first.sort, drawn("a1").map { |item| item.values_at("x", "y") }.sort
  end

  test "the model sees what's on the board, but not this ask's own drawing" do
    @doc.get_text("title").push("Bakery")
    @doc.get_map("items")["n1"] = { "type" => "note", "x" => 0, "y" => 0, "w" => 10, "h" => 10, "ask" => "a1" }
    @doc.get_map("items").get_map("n1").set_text("text", "old drawing")
    @doc.get_map("items")["n2"] = { "type" => "note", "x" => 0, "y" => 0, "w" => 10, "h" => 10 }
    @doc.get_map("items").get_map("n2").set_text("text", "Call the mill")
    person_asks("a1")
    model = FakeModel.new
    agent_with(model).answer_asks

    assert_equal "Title: Bakery\n- note: Call the mill", model.calls.first[:board]
  end

  test "a model failure shows on the ask" do
    person_asks("a1")
    agent_with(DownModel.new).answer_asks

    assert_equal "failed", ask("a1")["status"]
    assert_equal "the model timed out", ask("a1")["error"]
  end

  test "the canned plan draws a full timeline without a key" do
    person_asks("a1", prompt: "Lay out an illustrated timeline for the Huckleberry Pie launch, " \
                              "from locking the flavor to holiday delivery")
    agent_with(BoardModel::Canned.new).answer_asks

    notes = drawn("a1").select { |item| item["type"] == "note" }

    assert_equal 9, notes.size
    assert_equal "Lock flavor", notes.min_by { |n| n["z"] }["text"].lines.first.chomp
    assert_equal(3, drawn("a1").count { |item| item["type"] == "frame" && item["text"] != "Holiday delivery" })
  end

  test "other agents don't count as people" do
    agent = agent_with(FakeModel.new)
    person = Y::Awareness.new(101)
    other_agent = Y::Awareness.new(102)
    agent.send(:see, person.set_local_state(%({"user":{"name":"Ada","color":"#f87171"}})))
    agent.send(:see, other_agent.set_local_state(%({"user":{"name":"Bo's agent"},"agent":{"owner":"bo"}})))

    assert_equal [101], agent.people.keys
  end
end
