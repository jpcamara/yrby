require "test_helper"

# How BoardLayout places a board agent's plan, line by line.
class BoardLayoutTest < ActiveSupport::TestCase
  def layout(**) = @layout = BoardLayout.new(origin: [100, 200], id: counter, **)

  def counter
    n = 0
    -> { "i#{n += 1}" }
  end

  def add(*lines) = lines.flat_map { |line| @layout.add(line.is_a?(Hash) ? JSON.generate(line) : line) }

  def types(items) = items.map { |item| item.fields["type"] }

  def step(title, label: "Day 1", **) = { kind: "step", label:, title:, caption: "A caption", icon: "🥧", ** }

  test "a step is a pill with its label and a note under it" do
    layout
    pill, note = add(step("Lock flavor"))

    assert_equal "shape", pill.fields["type"]
    assert_equal "pill", pill.fields["shape"]
    assert_equal "Day 1", pill.text
    assert_equal "note", note.fields["type"]
    assert_equal "Lock flavor\nA caption", note.text
    assert_equal "🥧", note.fields["icon"]
    assert_operator note.fields["y"], :>, pill.fields["y"] + pill.fields["h"]
    assert_equal [note.fields["x"] + 100, note.fields["y"] + 66], note.at
  end

  test "each step after the first comes with the stretch of dashed path that leads to it" do
    layout
    add(step("One"))
    items = add(step("Two", label: "Day 2"))
    path, pill, = items

    assert_equal %w[path shape note], types(items)
    assert path.fields["dash"]
    assert_operator path.fields["z"], :<, pill.fields["z"]
    first, *, last = path.fields["points"].each_slice(2).map { |x, y| [x + path.fields["x"], y + path.fields["y"]] }

    assert_equal [pill.fields["x"] + 46, pill.fields["y"] + 17], last
    assert_equal BoardLayout::DX, last[0] - first[0]
  end

  test "the path winds back on the next row once a row is full" do
    layout
    pills = (1..6).map { |i| add(step("Step #{i}", label: "Day #{i}")).find { |item| item.fields["type"] == "shape" } }
    xs = pills.map { |pill| pill.fields["x"] }
    ys = pills.map { |pill| pill.fields["y"] }

    assert_equal xs.first(4), xs.first(4).sort
    assert_equal [xs[3], xs[2]], xs[4, 2]
    assert_equal 1, ys.first(4).uniq.size
    assert_equal ys[0] + BoardLayout::DY, ys[4]
  end

  test "a group starts a new row and gets a frame around its notes when it ends" do
    layout
    add({ kind: "group", text: "Recipe" }, step("One"), step("Two"))
    closed = add({ kind: "group", text: "Business" })
    after = add(step("Three"))

    frame = closed.first

    assert_equal ["frame"], types(closed)
    assert_equal "Recipe", frame.text
    assert_operator frame.fields["z"], :<, 0
    pill = after.find { |item| item.fields["type"] == "shape" }

    assert_operator pill.fields["y"], :>, frame.fields["y"] + frame.fields["h"]
    assert_equal ["frame"], types(@layout.finish)
  end

  test "a finale ends the path with an area, an icon, and a caption" do
    layout
    add(step("One"))
    items = add({ kind: "finale", title: "Holiday delivery", caption: "Pies at every door", icon: "🎁" })

    assert_equal %w[path shape frame sticker text], types(items)
    assert_equal "Holiday delivery", items[2].text
    assert_equal "🎁", items[3].fields["icon"]
  end

  test "a title goes to a board without one, and is a heading on a board with one" do
    layout
    title, = add({ kind: "title", text: "Pie launch", subtitle: "Twelve days" })

    assert_instance_of BoardLayout::Title, title
    assert_equal ["Pie launch", "Twelve days"], [title.text, title.subtitle]

    layout(titled: true)
    heading = add({ kind: "title", text: "Pie launch", subtitle: "Twelve days" })

    assert_equal %w[text text], types(heading)
    assert_equal [100, 200], heading.first.fields.values_at("x", "y")
  end

  test "notes go in a grid, four to a row" do
    layout
    notes = (1..5).flat_map { |i| add({ kind: "note", title: "Idea #{i}", icon: "💡" }) }

    assert_equal 1, notes.first(4).map { |n| n.fields["y"] }.uniq.size
    assert_equal 4, notes.first(4).map { |n| n.fields["x"] }.uniq.size
    assert_equal notes[0].fields["x"], notes[4].fields["x"]
    assert_operator notes[4].fields["y"], :>, notes[0].fields["y"]
  end

  test "a note in the middle of steps goes on the path, without a pill" do
    layout
    one = add(step("One")).last
    items = add({ kind: "note", title: "Farmers market", icon: "🧺" })

    assert_equal %w[path note], types(items)
    assert_equal [one.fields["x"] + BoardLayout::DX, one.fields["y"]], items.last.fields.values_at("x", "y")
  end

  test "lines it can't read are skipped, and it remembers the ones it placed" do
    layout
    items = add("```json", "", "not json", '{"kind":"step"}', '["a list"]', '{"kind":"dance"}', step("Real"))

    assert_equal %w[shape note], types(items)
    assert_equal 1, @layout.lines.size
    assert_equal "Real", JSON.parse(@layout.lines.first)["title"]
  end

  test "it cleans what the model wrote" do
    layout
    _, note = add(step("x" * 200, icon: "abc", color: "red; background: url(x)", caption: "two\nlines"))

    assert_equal 40, note.text.lines.first.chomp.size
    assert_nil note.fields["icon"]
    assert_equal BoardLayout::COLORS["yellow"], note.fields["color"]
    assert note.text.end_with?("two lines")
  end

  test "it stops placing after MAX_ITEMS" do
    layout
    100.times { |i| add(step("Step #{i}")) }

    assert_operator @layout.count, :<=, BoardLayout::MAX_ITEMS + 2
    assert_empty add(step("One more"))
  end

  test "the canned plan reads a subject, a start, and an end from the ask" do
    lines = +""
    BoardModel::Canned.new.plan("@agent Lay out an illustrated timeline for the Huckleberry Pie launch, " \
                                "from locking the flavor to holiday delivery", board: "") { |chunk| lines << chunk }
    plan = lines.lines.map { |line| JSON.parse(line) }

    assert_equal "Huckleberry Pie launch", plan.first["text"]
    steps = plan.select { |line| line["kind"] == "step" }

    assert_equal "Lock flavor", steps.first["title"]
    assert_includes steps.map { |s| s["title"] }, "Lock pricing"
    assert_includes steps.map { |s| s["title"] }, "Build pre-order forecast"
    assert_equal "Holiday delivery", plan.last["title"]
    assert_operator steps.size, :>=, 6
  end
end
