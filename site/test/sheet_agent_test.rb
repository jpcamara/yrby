require "test_helper"

# How one person's agent answers asks on the agent sheet, on a real Y::Doc
# without joining a room.
class SheetAgentTest < ActiveSupport::TestCase
  # A SheetAgent that edits `doc` directly, records its presence, and doesn't
  # pause between cells.
  class OfflineSheetAgent < SheetAgent
    Document = Data.define(:key, :name, :channel)

    attr_reader :doc, :presences

    def initialize(doc, **)
      @presences = []
      super(Document.new(key: "room/1/sheet", name: "sheet", channel: "RoomChannel"), url: "ws://unused", lock: nil, **)
      @doc = doc
    end

    def edit = @doc.edit { yield @doc }

    def presence=(state)
      @presences << state
      @presence = state
    end

    def sleep(_seconds) = nil
  end

  # Streams the given chunks and records what it was asked.
  class FakeModel
    attr_reader :calls

    def initialize(*chunks, &during)
      @chunks = chunks
      @during = during
      @calls = []
    end

    def fill(**args)
      @calls << args
      @chunks.each_with_index do |chunk, i|
        @during&.call(i)
        yield chunk
      end
    end
  end

  class DownModel
    def fill(**) = raise(AgentModel::Error, "the model timed out")
  end

  ADA = SheetAgent::Owner.new(id: "ada-0001", name: "Ada", color: "#f87171")
  Writes = SheetWrites

  setup do
    @doc = Y::Doc.new
    @doc.edit do
      @doc.get_array("tabs").push("preorders")
      @doc.get_array("tabs").push("historical")
      sheets = @doc.get_map("sheets")
      sheets["preorders"] = { "name" => "Pre-orders", "cells" => { "A1" => { "input" => "Mine", "bold" => true } } }
      sheets["historical"] = { "name" => "Historical",
                               "cells" => { "A2" => { "input" => "Website" }, "C2" => { "input" => "3200" } } }
    end
  end

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def cells(tab = "preorders") = @doc.get_map("sheets").get_map(tab).get_map("cells").to_h

  def person_asks(id, owner: ADA.id, status: "asked", **fields)
    @doc.edit do
      asks[id] = { "owner" => owner, "askedBy" => "Ada", "prompt" => "Draft a forecast", "tab" => "preorders",
                   "cell" => "B2", "status" => status, "createdAt" => 1 }.merge(fields)
    end
  end

  def agent_with(model) = @agent = OfflineSheetAgent.new(@doc, owner: ADA, model:)

  def lines(*objects) = objects.map { |o| "#{o.to_json}\n" }

  # --- reading the model's reply ---

  test "writes come out as soon as each object is complete, across chunks" do
    reader = Writes.new

    assert_empty(reader << '{"cell":"b4","inp')
    first = reader << 'ut":"=SUM(A1:A3)","format":"number","fill":"blue","bold":true}'

    assert_equal [Writes::Write.new(tab: nil, cell: "B4", input: "=SUM(A1:A3)", format: "number", bold: true,
                                    fill: "#dbe7fb")], first
  end

  test "fences, arrays, several per line, and braces inside strings are fine" do
    reader = Writes.new
    reply = %(```json\n[{"cell":"A1","input":"Totals {all}"}, {"cell":"A2","input":21000}]\n```\n{"say":"Done."})
    out = reader << reply

    assert_equal ["Totals {all}", "21000"], out.grep(Writes::Write).map(&:input)
    assert_equal "Done.", out.grep(Writes::Say).first.text
  end

  test "anything that isn't a valid write is dropped" do
    reader = Writes.new
    bad = lines({ cell: "A0", input: "x" }, { cell: "ZZZ1", input: "x" }, { cell: "A1", input: [1] },
                { cell: "A1", input: "ok", format: "bogus", fill: "plaid", bold: "yes" })
    out = reader << "#{bad.join}{not json}"

    assert_equal [Writes::Write.new(tab: nil, cell: "A1", input: "ok", format: nil, bold: nil, fill: nil)], out
  end

  # --- answering ---

  test "it writes each cell, marks it with the ask, and keeps the cells as they were" do
    person_asks("a1")
    model = FakeModel.new(*lines({ cell: "A1", input: "Channel", bold: true, fill: "gray" },
                                 { cell: "B2", input: "=SUMIFS(Historical!C:C, Historical!A:A, A2)", format: "number" },
                                 { cell: "B2", input: "=Historical!C2" },
                                 { say: "Built the forecast." }))
    agent_with(model).answer_asks

    assert_equal "done", ask("a1")["status"]
    assert_equal 3, ask("a1")["written"]
    assert_equal "Built the forecast.", ask("a1")["say"]
    assert_equal({ "input" => "Channel", "bold" => true, "fill" => "#ececec", "by" => "Ada's agent", "ask" => "a1" },
                 cells["A1"])
    assert_equal "=Historical!C2", cells["B2"]["input"]
    assert_equal "number", cells["B2"]["format"]
    # The first write to a cell is the one remembered, so Undo goes back to
    # before the ask.
    assert_equal({ "preorders!A1" => { "input" => "Mine", "bold" => true }, "preorders!B2" => {} },
                 ask("a1").get_map("before").to_h)
  end

  test "the model gets the sheet's inputs, the tab, and the selected cell" do
    person_asks("a1")
    model = FakeModel.new
    agent_with(model).answer_asks

    call = model.calls.first

    assert_equal "Pre-orders", call[:tab]
    assert_equal "B2", call[:selection]
    assert_equal "Draft a forecast", call[:prompt]
    assert_equal %(Tab "Pre-orders":\nA1: Mine\n\nTab "Historical":\nA2: Website\nC2: 3200), call[:sheet]
  end

  test "its cursor moves to each cell it writes, on the tab it writes" do
    person_asks("a1")
    agent_with(FakeModel.new(*lines({ cell: "A3", input: "x" }, { cell: "C9", input: "y", tab: "historical" })))
      .answer_asks

    cells = @agent.presences.filter_map { |p| p["cell"] }

    assert_equal [{ "tab" => "preorders", "ref" => "B2" }, { "tab" => "preorders", "ref" => "A3" },
                  { "tab" => "historical", "ref" => "C9" }], cells
    assert_equal "working", @agent.presences[1].dig("agent", "status")
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
    assert_equal "y", cells("historical")["C9"]["input"]
  end

  test "a write to a tab that doesn't exist is skipped" do
    person_asks("a1")
    agent_with(FakeModel.new(*lines({ cell: "A1", input: "x", tab: "Nope" }))).answer_asks

    assert_equal 0, ask("a1")["written"]
    assert_equal "Mine", cells["A1"]["input"]
  end

  test "it answers only its own person's open asks" do
    person_asks("mine")
    person_asks("theirs", owner: "linus-0002")
    person_asks("done", status: "undone")
    agent_with(FakeModel.new).answer_asks

    assert_equal(%w[done asked undone], %w[mine theirs done].map { |id| ask(id)["status"] })
  end

  test "a follow-up passes the earlier prompt back, and keeps the first record of each cell" do
    person_asks("a1")
    agent_with(FakeModel.new(*lines({ cell: "A1", input: "First" }))).answer_asks
    @doc.edit do
      ask("a1")["previous"] = "Draft a forecast"
      ask("a1")["prompt"] = "Shorter labels"
      ask("a1")["status"] = "asked"
    end
    model = FakeModel.new(*lines({ cell: "A1", input: "Second" }))
    agent_with(model).answer_asks

    assert_equal "Draft a forecast", model.calls.first[:previous]
    assert_equal "Second", cells["A1"]["input"]
    assert_equal({ "input" => "Mine", "bold" => true }, ask("a1").get_map("before").to_h["preorders!A1"])
  end

  test "stopping it mid-stream stops the writes" do
    person_asks("a1")
    model = FakeModel.new(*lines({ cell: "A2", input: "1" }, { cell: "A3", input: "2" },
                                 { cell: "A4", input: "3" })) do |i|
      @doc.edit { ask("a1")["status"] = "stopped" } if i == 1
    end
    agent_with(model).answer_asks

    assert_equal "stopped", ask("a1")["status"]
    assert_equal %w[A1 A2], cells.keys.sort
  end

  test "a model failure shows on the ask" do
    person_asks("a1")
    agent_with(DownModel.new).answer_asks

    assert_equal "failed", ask("a1")["status"]
    assert_equal "the model timed out", ask("a1")["error"]
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "its model gets no tools: the sheet is in the prompt and the reply is the writes" do
    assert_empty agent_with(FakeModel.new).document_tools
  end

  # --- the canned stand-in ---

  test "without a key, the forecast is formulas over the Historical tab, below what's there" do
    person_asks("a1")
    agent_with(SheetModel::Canned.new).answer_asks

    written = cells

    assert_equal "Mine", written["A1"]["input"]
    assert_equal "Holiday pies: 2026 pre-order forecast", written["A3"]["input"]
    assert_equal "=SUMIFS(Historical!C:C, Historical!A:A, A6)", written["B6"]["input"]
    assert_equal "Website", written["A6"]["input"]
    assert_equal "=SUM(F6:F9)", written["F10"]["input"]
    assert_operator(written.values.count { |c| c["input"].to_s.include?("Historical!") }, :>=, 6)
    assert_match(/canned/, ask("a1")["say"])
  end
end
