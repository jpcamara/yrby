require "test_helper"

# How one person's agent answers asks on the agent sheet, on a real Y::Doc
# without joining a room.
class SheetAgentTest < ActiveSupport::TestCase
  # A SheetAgent that edits `doc` directly, records its presence, and works
  # without pausing.
  class OfflineSheetAgent < SheetAgent
    Document = Data.define(:key, :name, :channel)

    attr_reader :doc, :presences

    def initialize(doc, **)
      @presences = []
      super(Document.new(key: "room/1/sheet", name: "sheet", channel: "RoomChannel"), url: "ws://unused", lock: nil,
                                                                                      pace: 0, **)
      @doc = doc
    end

    def edit = @doc.edit { yield @doc }

    def presence=(state)
      @presences << state
      @presence = state
    end
  end

  # Stands in for the model: says `before`, runs `script` with the agent's
  # real tools, as the model's tool calls would, records what it was asked,
  # and replies.
  class ScriptModel
    attr_reader :calls, :results
    attr_writer :agent

    def initialize(reply = "Built it.", before: nil, &script)
      @reply = reply
      @before = before
      @script = script
      @calls = []
      @results = []
    end

    def work(**asked)
      @calls << asked
      yield @before if @before
      tools = SheetTools.all(@agent).to_h { |tool| [tool.class.tool_name.to_sym, tool] }
      call = ->(name, **args) { (@results << tools.fetch(name).execute(**args)).last }
      @script&.call(call)
      yield @reply
    end
  end

  class DownModel
    def work(**) = raise(AgentModel::Error, "the model timed out")
  end

  ADA = SheetAgent::Owner.new(id: "ada-0001", name: "Ada", color: "#f87171")

  setup do
    @doc = Y::Doc.new
    @doc.edit do
      @doc.get_array("tabs").push("preorders")
      @doc.get_array("tabs").push("historical")
      sheets = @doc.get_map("sheets")
      sheets["preorders"] = { "name" => "Pre-orders", "cells" => { "A1" => { "input" => "Mine", "bold" => true } },
                              "widths" => {} }
      sheets["historical"] = { "name" => "Historical",
                               "cells" => { "A1" => { "input" => "Channel", "bold" => true, "fill" => "#ececec" },
                                            "A2" => { "input" => "Website" }, "C2" => { "input" => "3200" } },
                               "widths" => {} }
    end
  end

  def asks = @doc.get_map("asks")
  def ask(id) = asks.get_map(id)
  def cells(tab = "preorders") = @doc.get_map("sheets").get_map(tab).get_map("cells").to_h
  def saved(id, map) = ask(id).to_h[map] || {}

  def person_asks(id, owner: ADA.id, status: "asked", **fields)
    @doc.edit do
      asks[id] = { "owner" => owner, "askedBy" => "Ada", "prompt" => "Draft a forecast", "tab" => "preorders",
                   "cell" => "B2", "status" => status, "createdAt" => 1 }.merge(fields)
    end
  end

  def run_with(model)
    @agent = OfflineSheetAgent.new(@doc, owner: ADA, model:)
    model.agent = @agent if model.respond_to?(:agent=)
    @agent.answer_asks
    model
  end

  # --- writing ---

  test "it writes each cell the model gives, in order, marked with the ask, and keeps them for Undo" do
    person_asks("a1")
    model = run_with(ScriptModel.new("Built the forecast.") do |tool|
      tool.call(:write_cells, cells: [{ "ref" => "A1", "input" => "Channel", "bold" => true, "fill" => "pink" },
                                      { "ref" => "b2", "input" => "=SUMIFS(Historical!C:C, Historical!A:A, A2)",
                                        "format" => "number", "fill" => "light blue" },
                                      { "ref" => "C2", "input" => 0.1, "format" => "+percent" }])
    end)

    assert_equal "done", ask("a1")["status"]
    assert_equal 3, ask("a1")["written"]
    assert_equal "Built the forecast.", ask("a1")["say"]
    assert_equal({ "input" => "Channel", "bold" => true, "fill" => "#f9dbe0", "by" => "Ada's agent", "ask" => "a1" },
                 cells["A1"])
    assert_equal %w[number #eff4fd], cells["B2"].values_at("format", "fill")
    assert_equal "0.1", cells["C2"]["input"]
    assert_equal "Wrote 3 cells on Pre-orders, in A1:C2.", model.results.first
    assert_equal({ "preorders!A1" => { "input" => "Mine", "bold" => true }, "preorders!B2" => "",
                   "preorders!C2" => "" },
                 saved("a1", "before").transform_values { |json| json.empty? ? "" : JSON.parse(json) })
    assert_equal cells["A1"], JSON.parse(saved("a1", "after")["preorders!A1"])
  end

  test "it says which cells it skipped and why, and which formulas the sheet can't compute" do
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:write_cells, cells: [{ "ref" => "A0", "input" => "x" }, { "ref" => "B3", "format" => "bogus" },
                                      { "ref" => "B4", "input" => "=XLOOKUP(A4, Histrical!A:A, Historical!C:C)" },
                                      { "ref" => "B5", "input" => "=SUM(B1:B4)" }])
      tool.call(:write_cells, tab: "Nope", cells: [{ "ref" => "A1", "input" => "x" }])
    end)

    assert_equal <<~TEXT.chomp, model.results.first
      Wrote 2 cells on Pre-orders, in B4:B5.
      Check these formulas on Pre-orders:
      B4: XLOOKUP isn't a function here (there's SUM, AVERAGE, MIN, MAX, COUNT, ABS, ROUND, IF, SUMIF, SUMIFS)
      B4: there's no tab named Histrical
      A0: skipped, "A0" isn't a cell like B4
      B3: skipped, format must be one of number, percent, currency, text, +number, +percent, or auto
    TEXT
    assert_equal "Wrote nothing: there's no tab named Nope; the tabs are Pre-orders, Historical", model.results.last
  end

  test "the model reads tabs as inputs with their formatting, and its own cells say so" do
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:read_sheet, tab: "historical")
      tool.call(:write_cells, cells: [{ "ref" => "A3", "input" => "=Historical!C2", "format" => "number" }])
      tool.call(:read_sheet)
      tool.call(:read_sheet, tab: "Historical", range: "C1:C9")
    end)

    historical, _, everything, range = model.results

    assert_equal %(Tab "Historical":\nA1: Channel (bold, fill gray)\nA2: Website\nC2: 3200), historical
    assert_equal %(Tab "Pre-orders":\nA1: Mine (bold)\nA3: =Historical!C2 (number, yours)\n\n#{historical}), everything
    assert_equal %(Tab "Historical" C1:C9:\nC2: 3200), range
  end

  test "the model's prompt gets the tabs, where the person is, and what they asked" do
    person_asks("a1")
    call = run_with(ScriptModel.new).calls.first

    assert_equal ["Draft a forecast", "Ada", "Pre-orders", "B2"], call.values_at(:prompt, :asker, :tab, :selection)
    assert_equal %(- "Pre-orders": A1, 1 cells\n- "Historical": A1:C2, 3 cells), call[:sheet]
  end

  test "it outlines the block it's writing, and its cursor goes to each cell" do
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:write_cells, cells: [{ "ref" => "A3", "input" => "x" }, { "ref" => "C4", "input" => "y" }])
      tool.call(:write_cells, tab: "Historical", cells: [{ "ref" => "D9", "input" => "z" }])
    end)

    spots = @agent.presences.filter_map { |p| p["cell"] }

    assert_equal [{ "tab" => "preorders", "ref" => "B2" },
                  { "tab" => "preorders", "ref" => "A3", "range" => "A3:C4" },
                  { "tab" => "preorders", "ref" => "C4", "range" => "A3:C4" },
                  { "tab" => "historical", "ref" => "D9", "range" => "D9" }], spots
    assert_equal "a1", @agent.presences[1].dig("agent", "ask")
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
    assert_equal "z", cells("historical")["D9"]["input"]
  end

  test "its card shows what the model said and what it's doing, then only what it said after its last tool call" do
    person_asks("a1")
    seen = []
    run_with(ScriptModel.new("Built a forecast.", before: "You got it.") do |tool|
      tool.call(:read_sheet, tab: "Historical")
      seen << ask("a1").to_h.slice("say", "doing")
      tool.call(:write_cells, cells: [{ "ref" => "A3", "input" => "x" }, { "ref" => "A4", "input" => "y" }])
      seen << ask("a1").to_h.slice("say", "doing")
    end)

    assert_equal [{ "say" => "You got it.", "doing" => "Reading Historical" },
                  { "say" => "You got it.", "doing" => "Writing A3:A4" }], seen
    assert_equal({ "say" => "Built a forecast." }, ask("a1").to_h.slice("say", "doing"))
  end

  test "it formats and clears ranges, and Undo can put back what they held" do
    @doc.edit { @doc.get_map("sheets").get_map("preorders").get_map("cells")["B1"] = { "input" => "5" } }
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:format_range, range: "B1:B2", fill: "light green", format: "number")
      tool.call(:clear_range, range: "A1:A9")
    end)

    assert_equal({ "B1" => { "input" => "5", "fill" => "#eef8f1", "format" => "number" },
                   "B2" => { "fill" => "#eef8f1", "format" => "number" } }, cells)
    assert_equal 3, ask("a1")["written"]
    before = saved("a1", "before")

    assert_equal([{ "input" => "5" }, "", { "input" => "Mine", "bold" => true }],
                 %w[B1 B2 A1].map { |ref| (json = before["preorders!#{ref}"]).empty? ? "" : JSON.parse(json) })
    assert_equal "", saved("a1", "after")["preorders!A1"]
  end

  test "it sizes columns, keeping the old width for Undo" do
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:resize_columns, columns: [{ "column" => "a", "width" => 260 }]) })

    assert_equal({ "A" => 260 }, @doc.get_map("sheets").get_map("preorders").get_map("widths").to_h)
    assert_equal(["", "260"], [saved("a1", "before"), saved("a1", "after")].map { |map| map["preorders!width:A"] })
  end

  test "it adds and renames tabs; formulas follow a rename" do
    @doc.edit { @doc.get_map("sheets").get_map("preorders").get_map("cells")["B1"] = { "input" => "=Historical!C2" } }
    person_asks("a1")
    model = run_with(ScriptModel.new do |tool|
      tool.call(:write_cells, cells: [{ "ref" => "B2", "input" => "=SUM(Historical!C:C)" }])
      tool.call(:rename_tab, tab: "Historical", name: "Last year")
      tool.call(:add_tab, name: "Notes")
      tool.call(:write_cells, tab: "Notes", cells: [{ "ref" => "A1", "input" => "Hi" }])
      tool.call(:add_tab, name: "notes")
    end)

    tabs = @doc.get_array("tabs").to_a
    names = tabs.map { |id| @doc.get_map("sheets").get_map(id)["name"] }

    assert_equal ["Pre-orders", "Last year", "Notes"], names
    assert_equal(["='Last year'!C2", "=SUM('Last year'!C:C)"], cells.values_at("B1", "B2").map { |c| c["input"] })
    assert_equal "=SUM('Last year'!C:C)", JSON.parse(saved("a1", "after")["preorders!B2"])["input"]
    assert_equal [tabs.last], JSON.parse(ask("a1")["addedTabs"])
    assert_equal({ "historical" => ["Historical", "Last year"] }, JSON.parse(ask("a1")["renamedTabs"]))
    assert_equal "Hi", cells(tabs.last)["A1"]["input"]
    assert_equal "Added no tab: there's already a tab named notes", model.results.last
  end

  test "it answers only its own person's open asks" do
    person_asks("mine")
    person_asks("theirs", owner: "linus-0002")
    person_asks("done", status: "undone")
    run_with(ScriptModel.new)

    assert_equal(%w[done asked undone], %w[mine theirs done].map { |id| ask(id)["status"] })
  end

  test "an ask for a change gives the model the earlier prompt and what it said, and keeps the first record" do
    person_asks("a1")
    run_with(ScriptModel.new { |tool| tool.call(:write_cells, cells: [{ "ref" => "A1", "input" => "First" }]) })
    @doc.edit do
      ask("a1")["previous"] = "Draft a forecast"
      ask("a1")["said"] = "Built it."
      ask("a1")["prompt"] = "Shorter labels"
      ask("a1")["status"] = "asked"
    end
    model = run_with(ScriptModel.new { |tool| tool.call(:write_cells, cells: [{ "ref" => "A1", "input" => "2nd" }]) })

    assert_equal ["Draft a forecast", "Built it."], model.calls.first.values_at(:previous, :said)
    assert_equal "2nd", cells["A1"]["input"]
    assert_equal({ "input" => "Mine", "bold" => true }, JSON.parse(saved("a1", "before")["preorders!A1"]))
  end

  test "stopping it mid-call keeps what it wrote and writes no more" do
    person_asks("a1")
    run_with(ScriptModel.new do |tool|
      tool.call(:write_cells, cells: [{ "ref" => "A2", "input" => "1" }])
      @doc.edit { ask("a1")["status"] = "stopped" }
      tool.call(:write_cells, cells: [{ "ref" => "A3", "input" => "2" }])
    end)

    assert_equal "stopped", ask("a1")["status"]
    assert_equal %w[A1 A2], cells.keys.sort
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "an ask stops changing the sheet after its limit" do
    person_asks("a1")
    stub_const(SheetWrites, :MAX_CHANGES, 2) do
      model = run_with(ScriptModel.new do |tool|
        tool.call(:write_cells, cells: %w[A2 A3 A4].map { |ref| { "ref" => ref, "input" => "x" } })
      end)

      assert_equal %w[A1 A2 A3], cells.keys.sort
      assert_match(/this ask has changed 2 cells and can change 2; stop and reply/, model.results.first)
    end
  end

  test "a model failure shows on the ask" do
    person_asks("a1")
    run_with(DownModel.new)

    assert_equal "failed", ask("a1")["status"]
    assert_equal "the model timed out", ask("a1")["error"]
    assert_equal "idle", @agent.presences.last.dig("agent", "status")
  end

  test "its model gets the sheet tools" do
    names = run_with(ScriptModel.new).then { @agent.document_tools.map { |tool| tool.class.tool_name } }

    assert_equal %w[read_sheet write_cells format_range clear_range resize_columns add_tab rename_tab], names
  end

  test "the sheet knows the functions formula.js has" do
    source = Rails.root.join("frontend/src/formula.js").read
    functions = source[/const FUNCTIONS = \{(.*?)\n\}/m, 1].scan(/^  ([A-Z]+):/).flatten

    assert_equal functions.sort, SheetSpec::FUNCTIONS.sort
  end

  test "renaming a tab rewrites formulas as formula.js does, leaving strings alone" do
    assert_equal %(=SUM('Last year'!C:C)+'Last year'!A1&"Historical!A1"&Other!B2),
                 SheetSpec.rename(%(=SUM(Historical!C:C)+'historical'!A1&"Historical!A1"&Other!B2), "Historical",
                                  "Last year")
    assert_equal "plain Historical!A1", SheetSpec.rename("plain Historical!A1", "Historical", "X")
  end

  # --- the canned stand-in ---

  test "without a key, the forecast is formulas over the Historical tab, below what's there, through the same writes" do
    person_asks("a1")
    @agent = OfflineSheetAgent.new(@doc, owner: ADA, model: nil)
    @agent.instance_variable_set(:@model, SheetModel::Canned.new(@agent))
    @agent.answer_asks

    written = cells

    assert_equal "done", ask("a1")["status"]
    assert_equal "Mine", written["A1"]["input"]
    assert_equal ["Channel", "#f9dbe0", true], written["A3"].values_at("input", "fill", "bold")
    assert_equal "=SUMIFS(Historical!C:C, Historical!A:A, A4)", written["B4"]["input"]
    assert_equal "=SUM(F4:F7)", written["F8"]["input"]
    assert_equal "=ROUND(D8/Historical!C16, 1)", written["D11"]["input"]
    assert_equal written.size, ask("a1")["written"] # every cell but A1, and column A's width
    assert_match(/canned/, ask("a1")["say"])
    assert(@agent.presences.any? { |p| p.dig("cell", "range") == "A4:G8" })
  end
end
