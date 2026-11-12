require "test_helper"

# How one person's agent answers asks on a board, on a real Y::Doc without
# joining a room. test/boards_test.rb covers the page and the invitation.
class BoardAgentTest < ActiveSupport::TestCase
  # A BoardAgent that edits `doc` directly, records its presence, and works
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

  # Stands in for the model: runs `script` with the agent's real tools, as
  # the model's tool calls would, records what it was asked, and replies.
  class ScriptModel
    attr_reader :calls, :results, :reviews

    def initialize(reply = "Drew it.", &script)
      @reply = reply
      @script = script
      @calls = []
      @results = []
      @tools = nil
    end

    attr_writer :agent

    def draw(**asked)
      @calls << asked
      tools = BoardTools.all(@agent).to_h { |tool| [tool.class.tool_name.to_sym, tool] }
      call = ->(name, **args) { (@results << tools.fetch(name).execute(**args)).last }
      @script&.call(call)
      yield @reply
    end

    # What it was told overlapped at the end, if anything.
    def review(overlaps:)
      @reviews = [*@reviews, overlaps]
      nil
    end
  end

  class DownModel
    def draw(**) = raise(AgentModel::Error, "the model timed out")
  end

  ADA = PageAgent::Owner.new(id: "ada-0001", name: "Ada", color: "#f87171")
  NOTE = { "type" => "note", "x" => 100, "y" => 100, "title" => "Lock flavor", "caption" => "Pick it",
           "icon" => "🥧" }.freeze

  setup { @doc = Y::Doc.new }

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def items = JSON.parse(@doc.read_map("items"))
  def added(id) = items.select { |_key, item| item["ask"] == id }

  def person_asks(id, owner: ADA.id, status: "asked", **fields)
    asks[id] = { "owner" => owner, "askedBy" => "Ada", "prompt" => "Plan the pie launch",
                 "at" => { "x" => 40, "y" => 60 }, "view" => { "x" => 0, "y" => 50, "w" => 1200, "h" => 700 },
                 "status" => status, "createdAt" => 1 }.merge(fields)
  end

  def person_note(key, text, **fields)
    @doc.get_map("items")[key] = { "type" => "note", "x" => 500, "y" => 500, "w" => 200, "h" => 132, "z" => 3,
                                   "color" => "#bfdbfe", "by" => "someone" }.merge(fields)
    @doc.get_map("items").get_map(key).set_text("text", text)
  end

  # Draws every subject at once as one circle, or fails (nil) for "nothing".
  class InstantArtist
    attr_reader :subjects

    def initialize = @subjects = []

    def start(subject)
      @subjects << subject
      art = subject == "nothing" ? nil : { "box" => [0, 0, 100, 100], "shapes" => [["circle", { "r" => "40" }, []]] }
      Thread.new { art }.tap(&:join)
    end
  end

  def run_with(model, artist: nil)
    @agent = OfflineBoardAgent.new(@doc, owner: ADA, model:, artist:)
    model.agent = @agent if model.respond_to?(:agent=)
    @agent.answer_asks
    model
  end

  test "it adds what the model asks for, where it says, marked with the ask" do
    person_asks("a1")
    model = run_with(ScriptModel.new("Added a note and a frame.") do |tool|
      tool.call(:add_items, items: [NOTE, { "type" => "frame", "x" => 60, "y" => 40, "w" => 300, "h" => 240,
                                            "text" => "Recipe", "color" => "green" }])
    end)

    assert_equal "done", ask("a1")["status"]
    assert_equal "Added a note and a frame.", ask("a1")["plan"]
    assert_equal 2, ask("a1")["drawn"]
    note, frame = added("a1").values.partition { |item| item["type"] == "note" }.map(&:first)

    assert_equal [100, 100, 180, 200, "#fde68a", "🥧"], note.values_at("x", "y", "w", "h", "color", "icon")
    assert_equal "Lock flavor\nPick it", note["text"]
    assert_equal "#bbf7d0", frame["color"]
    assert_operator frame["z"], :<, note["z"], "frames go under"
    assert(added("a1").values.all? { |item| item["by"] == "agent:ada-0001" })
    assert_match(/item 1: added as \w+\nitem 2: added as \w+/, model.results.first)
  end

  test "items sent as a JSON string, or as JSON strings, are read like objects" do
    person_asks("a1")
    run_with(ScriptModel.new do
      tool = BoardTools::AddItems.new(@agent)
      tool.call(items: JSON.generate([NOTE]))
      tool.call(items: [JSON.generate(NOTE.merge("x" => 400))])
    end)

    assert_equal [100, 400], added("a1").values.map { |item| item["x"] }.sort
  end

  test "items whose JSON doesn't parse go back to the model as an error, and the ask goes on" do
    person_asks("a1")
    results = []
    run_with(ScriptModel.new do
      tool = BoardTools::AddItems.new(@agent)
      results << tool.call(items: '[{"type": "note", "x": 100, "y", "y": 100}]')
      results << tool.call(items: [NOTE])
    end)

    assert_match(/weren't valid JSON/, results.first[:error])
    assert_equal 1, added("a1").size
    assert_equal "done", ask("a1")["status"]
  end

  test "answering leaves Y::Collaborator's update queue alone, so the agent keeps following the board" do
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE]) })

    assert_kind_of Thread::Queue, @agent.instance_variable_get(:@changes)
  end

  test "a tool that fails tells the model why, and after a few failures the ask fails" do
    person_asks("a1")
    results = []
    run_with(ScriptModel.new do
      @agent.define_singleton_method(:board_listing) { raise ArgumentError, "the board is busy" }
      look = BoardTools::LookAtBoard.new(@agent)
      results << look.call
      BoardSteps::MAX_FAILURES.times { results << look.call }
    end)

    assert_match(/That call failed \(the board is busy\)/, results.first[:error])
    assert_equal BoardSteps::MAX_FAILURES - 1, results.size
    assert_equal "failed", ask("a1")["status"]
    assert_match(/kept failing/, ask("a1")["error"])
  end

  test "a note that lands on a thick road hears about it, and one beside the road doesn't" do
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "type" => "path", "points" => [[0, 300], [800, 300]], "stroke" => 16 },
                                    NOTE.merge("x" => 100, "y" => 200),
                                    NOTE.merge("x" => 400, "y" => 20)])
    end)

    road, on, off = model.results.first.lines

    assert_no_match(/overlaps/, road)
    assert_match(/overlaps \w+ \(path\)/, on)
    assert_no_match(/overlaps/, off)
  end

  test "connectors join items by id or by a ref from the same call, and bad ones are skipped with a reason" do
    person_note("mill", "Call the mill")
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE.merge("ref" => "flavor"),
                                    { "type" => "connector", "from" => "flavor", "to" => "mill" },
                                    { "type" => "connector", "from" => "flavor", "to" => "nowhere" },
                                    { "type" => "sticker", "x" => 0, "y" => 0 }])
    end)

    connector = added("a1").values.find { |item| item["type"] == "connector" }
    flavor = added("a1").find { |_key, item| item["type"] == "note" }.first

    assert_equal [flavor, "mill"], connector.values_at("from", "to")
    assert_match(/item 3: skipped, a connector's to must be the id of an item/, model.results.first)
    assert_match(/item 4: skipped, a sticker needs an emoji icon/, model.results.first)
  end

  test "a sticker or pill with on sits centered on the road, at its point nearest where it was put, by any ref" do
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "ref" => "road", "type" => "path", "stroke" => 24,
                                      "points" => [[100, 400], [500, 400], [900, 200]] },
                                    { "type" => "sticker", "icon" => "🚚", "w" => 100, "h" => 100,
                                      "x" => 250, "y" => 100, "on" => "road" },
                                    { "type" => "sticker", "icon" => "🚚", "x" => 0, "y" => 0, "on" => "nowhere" }])
      tool.call(:add_items, items: [{ "type" => "shape", "shape" => "pill", "w" => 80, "h" => 30,
                                      "x" => 860, "y" => 100, "on" => "road" }])
    end)

    truck, pill = %w[sticker shape].map { |type| added("a1").values.find { |item| item["type"] == type } }

    assert_equal [250, 350], truck.values_at("x", "y")
    assert_equal [860, 185], pill.values_at("x", "y")
    assert_match(/item 3: skipped, on must be the id or ref of a path/, model.results.first)
  end

  test "a sticker on the road moves along it to clear space rather than cover a pill" do
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "ref" => "road", "type" => "path", "stroke" => 24,
                                      "points" => [[0, 400], [1000, 400]] },
                                    { "type" => "shape", "shape" => "pill", "w" => 80, "h" => 30,
                                      "x" => 460, "y" => 385, "on" => "road" },
                                    { "type" => "sticker", "icon" => "🚚", "w" => 100, "h" => 100,
                                      "x" => 450, "y" => 350, "on" => "road" }])
    end)

    truck = added("a1").values.find { |item| item["type"] == "sticker" }

    assert_equal 350, truck["y"]
    assert truck["x"] >= 540 || truck["x"] <= 360, "the truck covers the pill at x=#{truck["x"]}"
  end

  test "a sticker on a crowded road gets smaller to fit on it" do
    person_note("banner", "Launch week", "x" => -500, "y" => 130, "w" => 1300, "h" => 200)
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "ref" => "road", "type" => "path", "stroke" => 24,
                                      "points" => [[0, 400], [300, 400]] },
                                    { "type" => "sticker", "icon" => "🚚", "w" => 200, "h" => 200,
                                      "x" => 50, "y" => 300, "on" => "road" }])
    end)

    truck = added("a1").values.find { |item| item["type"] == "sticker" }

    assert_equal [120, 120, 340], truck.values_at("w", "h", "y")
  end

  test "a line counts where it crosses an item, but not a rider on it or a connector's own ends" do
    person_note("left", "Start", "x" => 0, "y" => 0)
    person_note("right", "End", "x" => 600, "y" => 0)
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "type" => "connector", "from" => "left", "to" => "right" },
                                    NOTE.merge("x" => 300, "y" => 0),
                                    { "ref" => "road", "type" => "path", "stroke" => 24,
                                      "points" => [[0, 600], [800, 600]] },
                                    { "type" => "sticker", "icon" => "🚚", "x" => 100, "y" => 560, "on" => "road" },
                                    { "type" => "text", "text" => "Holiday pies", "x" => 500, "y" => 590 }])
    end)

    line, note, road, truck, caption = model.results.first.lines

    assert_no_match(/overlaps/, line)
    assert_match(/overlaps \w+ \(connector\)/, note)
    assert_no_match(/overlaps/, road)
    assert_no_match(/overlaps/, truck)
    assert_match(/overlaps \w+ \(path\)/, caption)
  end

  test "it lists what overlaps when it looks, and gets one turn to fix it before it's done" do
    person_note("mill", "Call the mill")
    person_asks("a1")
    listing = nil
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE.merge("x" => 550, "y" => 550)])
      listing = tool.call(:look_at_board)
    end)

    overlap = listing[/Overlapping now:\n(.*)/m, 1]

    assert_match(/\A- .* and .*\z/, overlap)
    assert_includes overlap, 'mill (note "Call the mill")'
    assert_includes overlap, '(note "Lock flavor Pick it")'
    assert_equal [overlap], model.reviews
  end

  test "an ask whose items overlap nothing gets no review" do
    person_asks("a1")
    model = run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE]) })

    assert_nil model.reviews
  end

  test "an overlap names what's covered, by its type and words" do
    person_note("map", "Route map", "x" => 0, "y" => 0)
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [{ "type" => "text", "text" => "48 states", "x" => 20, "y" => 40 }])
    end)

    assert_match(/overlaps map \(note "Route map"\)/, model.results.first)
  end

  test "it moves and rewords people's items, and keeps what they were for Undo" do
    person_note("mill", "Call the mill")
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:update_items,
                changes: [{ "id" => "mill", "x" => 40, "color" => "pink", "title" => "Call the mill today" }])
    end)

    mill = items["mill"]

    assert_equal [40, 500, "#fbcfe8", "Call the mill today", "someone"], mill.values_at("x", "y", "color", "text", "by")
    before = JSON.parse(ask("a1").to_h["before"]["mill"])
    after = JSON.parse(ask("a1").to_h["after"]["mill"])

    assert_equal [500, "Call the mill", "#bfdbfe"], before.values_at("x", "text", "color")
    assert_equal mill, after
  end

  test "changing a note's caption keeps its title, and a shape takes a title as its label" do
    person_note("mill", "Call the mill\nBy Friday")
    @doc.get_map("items")["head"] = { "type" => "shape", "x" => 0, "y" => 0, "w" => 300, "h" => 60 }
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:update_items, changes: [{ "id" => "mill", "caption" => "By Monday" },
                                         { "id" => "head", "title" => "To do" }])
    end)

    texts = items.values_at("mill", "head").map { |item| item["text"] }

    assert_equal ["Call the mill\nBy Monday", "To do"], texts
  end

  test "it tells the model when what it added overlaps something" do
    person_note("mill", "Call the mill")
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE.merge("x" => 550, "y" => 550), NOTE.merge("x" => 2000)])
    end)

    assert_match(/item 1: added as \w+, but it overlaps mill \(note "Call the mill"\)\nitem 2: added as \w+\z/,
                 model.results.first)
  end

  test "its reply is what it said after its last tool call" do
    person_asks("a1")
    model = Class.new(ScriptModel) do
      def draw(**asked)
        @calls << asked
        yield "Let me fix that:"
        BoardTools::LookAtBoard.new(@agent).execute
        yield "Drew a kanban board."
      end
    end
    run_with(model.new)

    assert_equal "Drew a kanban board.", ask("a1")["plan"]
  end

  test "deleting an item takes its connectors with it, and Undo can bring both back" do
    person_note("mill", "Call the mill")
    person_note("farm", "Call the farm", x: 900)
    @doc.get_map("items")["link"] = { "type" => "connector", "from" => "farm", "to" => "mill", "z" => 4 }
    person_asks("a1")
    model = run_with(ScriptModel.new { |tool| tool.call(:delete_items, ids: ["mill"]) })

    assert_equal ["farm"], items.keys
    assert_equal "mill: deleted with 1 connector(s)", model.results.first
    saved = ask("a1").to_h

    assert_equal %w[link mill], saved["before"].keys.sort
    assert_equal({ "link" => "", "mill" => "" }, saved["after"])
  end

  test "it sets the title, keeping the old one for Undo" do
    @doc.get_text("title").push("Bakery")
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:set_title, title: "Pie launch", subtitle: "Twelve days") })

    assert_equal ["Pie launch", "Twelve days"], [@doc.read_text("title"), @doc.read_text("subtitle")]
    assert_equal ["Bakery", ""], JSON.parse(ask("a1")["titleBefore"])
    assert_equal ["Pie launch", "Twelve days"], JSON.parse(ask("a1")["titleAfter"])
  end

  test "the model reads the board with ids and places, and the area the person could see" do
    @doc.get_text("title").push("Bakery")
    person_note("mill", "Call the mill")
    person_asks("a1")
    model = run_with(ScriptModel.new { |tool| tool.call(:look_at_board) })

    asked = model.calls.first

    assert_equal [0, 50, 1200, 700], asked[:view]
    assert_equal "Plan the pie launch", asked[:prompt]
    assert_equal "Title: Bakery\nItems (1):\nmill note x=500 y=500 w=200 h=132 blue \"Call the mill\"", asked[:board]
    assert_equal asked[:board], model.results.first
  end

  test "its cursor goes to each change, and its presence says it's working on the ask" do
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE, NOTE.merge("x" => 400)]) })

    cursors = @agent.presences.filter_map { |p| p["cursor"] }.uniq

    assert_equal [{ "x" => 190, "y" => 200 }, { "x" => 490, "y" => 200 }], cursors
    working = @agent.presences.find { |p| p.dig("agent", "status") == "working" }

    assert_equal "a1", working.dig("agent", "ask")
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "it answers only its own person's open asks, oldest first" do
    person_asks("mine")
    person_asks("theirs", owner: "linus-0002")
    person_asks("undone", status: "undone")
    run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE]) })

    assert_equal(%w[done asked undone], %w[mine theirs undone].map { |id| ask(id)["status"] })
    assert_empty added("theirs")
  end

  test "stopping it mid-call keeps what it did and does no more" do
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE])
      asks.get_map("a1")["status"] = "stopped"
      tool.call(:add_items, items: [NOTE, NOTE])
    end)

    assert_equal "stopped", ask("a1")["status"]
    assert_equal 1, added("a1").size
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "an ask for a change gives the model what it said and was asked before" do
    person_asks("a1", prompt: "Fewer steps", earlier: "Plan the pie launch", previous: "Drew nine steps.")
    model = run_with(ScriptModel.new)

    assert_equal ["Fewer steps", "Plan the pie launch", "Drew nine steps."],
                 model.calls.first.values_at(:prompt, :earlier, :previous)
  end

  test "it selects every item a call changes, and says what it's doing on the card" do
    person_note("mill", "Call the mill")
    person_note("farm", "Call the farm", x: 900)
    person_asks("a1")
    activity = nil
    run_with(ScriptModel.new do |tool|
      tool.call(:update_items, changes: [{ "id" => "mill", "x" => 0 }, { "id" => "farm", "x" => 300 }])
      activity = ask("a1")["activity"]
    end)

    assert_equal "Moving 2 items", activity
    assert_includes @agent.presences.map { |p| p["selection"] }, %w[mill farm]
    assert_nil ask("a1")["activity"]
    assert_nil @agent.presences.last["selection"]
  end

  test "an item that crosses a frame's edge counts as an overlap; one inside it doesn't" do
    @doc.get_map("items")["box"] = { "type" => "frame", "x" => 0, "y" => 100, "w" => 400, "h" => 300, "z" => 1 }
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE.merge("x" => 40, "y" => 140), NOTE.merge("x" => 300, "y" => 140)])
    end)

    assert_match(/item 1: added as \w+\n/, model.results.first)
    assert_match(/item 2: added as \w+, but it overlaps box/, model.results.first)
  end

  test "an ask stops changing the board after its limit" do
    person_asks("a1")
    stub_const(BoardSteps, :MAX_CHANGES, 2) do
      model = run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE] * 3) })

      assert_equal 2, added("a1").size
      assert_match(/item 3: skipped, this ask has made 2 changes/, model.results.first)
    end
  end

  test "a model failure shows on the ask" do
    person_asks("a1")
    run_with(DownModel.new)

    assert_equal "failed", ask("a1")["status"]
    assert_equal "the model timed out", ask("a1")["error"]
  end

  test "the canned plan draws a full timeline through the same writes, without a key" do
    person_asks("a1", prompt: "Lay out an illustrated timeline for the Huckleberry Pie launch, " \
                              "from locking the flavor to holiday delivery")
    @agent = OfflineBoardAgent.new(@doc, owner: ADA, model: nil)
    @agent.instance_variable_set(:@model, BoardModel::Canned.new(@agent))
    @agent.answer_asks

    notes = added("a1").values.select { |item| item["type"] == "note" }

    assert_equal "done", ask("a1")["status"]
    assert_equal 9, notes.size
    assert_equal "Lock flavor", notes.min_by { |n| n["z"] }["text"].lines.first.chomp
    assert_equal "Huckleberry Pie launch", @doc.read_text("title")
    assert_match(/canned plan/, ask("a1")["plan"])
  end

  test "other agents don't count as people" do
    agent = OfflineBoardAgent.new(@doc, owner: ADA, model: DownModel.new)
    person = Y::Awareness.new(101)
    other_agent = Y::Awareness.new(102)
    agent.send(:see, person.set_local_state(%({"user":{"name":"Ada","color":"#f87171"}})))
    agent.send(:see, other_agent.set_local_state(%({"user":{"name":"Bo's agent"},"agent":{"owner":"bo"}})))

    assert_equal [101], agent.people.keys
  end

  test "a note's drawing lands on it as art, and its emoji shows until then" do
    person_asks("a1")
    artist = InstantArtist.new
    model = run_with(ScriptModel.new do |tool|
      tool.call(:add_items, items: [NOTE.merge("drawing" => "a slice of pie"),
                                    { "type" => "sticker", "x" => 400, "y" => 100, "drawing" => "a truck" }])
      tool.call(:look_at_board)
    end, artist:)

    assert_equal "done", ask("a1")["status"]
    assert_equal ["a slice of pie", "a truck"], artist.subjects
    note, sticker = added("a1").values.sort_by { |item| item["x"] }

    assert_equal "🥧", note["icon"]
    assert_equal [["circle", { "r" => "40" }, []]], JSON.parse(note["art"])["shapes"]
    assert sticker["art"], "a sticker can be just a drawing"
    assert_equal 4, ask("a1")["drawn"], "each drawing lands as its own change"
    assert_includes model.results.last, "drawing of a slice of pie"
  end

  test "a finished drawing lands before the model's next tool call" do
    person_asks("a1")
    seen = nil
    run_with(ScriptModel.new do
      BoardTools::AddItems.new(@agent).call(items: [NOTE.merge("drawing" => "a pie")])
      seen = BoardTools::LookAtBoard.new(@agent).call
    end, artist: InstantArtist.new)

    assert_equal(1, items.values.count { |item| item["art"] })
    assert_match(/drawing of a pie/, seen)
  end

  test "a drawing that fails leaves the emoji" do
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:add_items, items: [NOTE.merge("drawing" => "nothing")]) },
             artist: InstantArtist.new)

    assert_equal "done", ask("a1")["status"]
    assert_nil added("a1").values.first["art"]
    assert_equal "🥧", added("a1").values.first["icon"]
  end

  private

  def stub_const(owner, name, value)
    old = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, old)
  end
end
