# frozen_string_literal: true

require "city_helper"
require "city_cable"

# The planner against a real cable: Puma serving Action Cable in this
# process, a room-keyed channel that records to a hash, the planner joined
# over one socket and a person over another. Everything between them goes
# through the document.
class CityPlannerTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- one test per behaviour
  include CityCable

  def setup
    @key = "city-#{rand(1 << 32)}"
  end

  def teardown
    @planner&.stop
    @thread&.join(5)
    close_clients
  end

  # A person joined, with everyone's presence mirrored in `seen`, and the
  # planner there and idle. Presence is not replayed on a join, so the
  # person says theirs once the planner is in.
  def join(mayor: nil)
    seen = Y::Awareness.new
    person = client.on_awareness { |frame| seen.apply_update(frame) }.subscribe
    @planner = CityPlanner.new(@key, peer: client, logger: Logger.new(File::NULL), mayor: mayor)
    @thread = Thread.new { @planner.run }
    wait_until { planner_state(seen) }
    present(person)
    [person, seen]
  end

  def planner_state(seen) = seen.states.values.find { |s| s.is_a?(Hash) && s["planner"] }

  # What the page writes for a paint: the tile and its author together.
  def paint(client, cells, tile, name: "Ada")
    client.send_update(client.doc.diff do |d|
      cells.each do |x, y|
        d.get_map("tiles")[City.key(x, y)] = tile
        d.get_map("authors")[City.key(x, y)] = "h:#{name}"
      end
    end)
  end

  # What the page writes for a sign: the tile, its author, and the text.
  def place_sign(client, cell, text)
    client.send_update(client.doc.diff do |d|
      d.get_map("tiles")[City.key(*cell)] = "sign"
      d.get_map("authors")[City.key(*cell)] = "h:Ada"
      d.get_map("signs")[City.key(*cell)] = text
    end)
  end

  # The planner's presence once it says it is idle.
  def idle(seen)
    wait_until { planner_state(seen)["status"] == "idle" }
    planner_state(seen)
  end

  def test_the_planner_joins_as_a_peer_and_connects_two_houses_with_a_road
    person, seen = join

    assert_equal({ "name" => "Planner", "color" => "#e38628" }, planner_state(seen)["user"])
    assert_equal "idle", planner_state(seen)["status"]

    paint(person, [[10, 10]], "house_red")
    paint(person, [[16, 10]], "house_blue")
    road = (11..15).map { |x| City.key(x, 10) }
    wait_until(timeout: 15) { road.all? { |k| read(person, "tiles")[k] == "road" } }

    assert_equal road.to_h { |k| [k, "a:planner"] }, read(person, "authors").slice(*road), "the planner signed its road"
    wait_until { read(person, "claims").empty? }

    assert_equal({ "x" => 15, "y" => 10 }, idle(seen)["pos"], "its character stands on the last tile it laid")
    assert_operator recorded(@key), :>=, 7, "the server recorded the planner's writes"
  end

  def test_the_planner_claims_the_cells_first_and_yields_when_someone_writes_beside_them
    person, seen = join

    paint(person, [[2, 20]], "house_red")
    paint(person, [[40, 20]], "house_blue")
    wait_until { read(person, "claims").size >= 30 }

    assert(read(person, "claims").values.all? { |v| v == "planner" })
    paint(person, [[20, 22]], "park")
    wait_until { planner_state(seen)["status"] == "yielding to Ada" }
    wait_until { read(person, "claims").empty? }

    laid = read(person, "tiles").count { |_, tile| tile == "road" }

    assert_operator laid, :<, 37, "it stopped short"
    idle(seen)
  end

  def test_a_park_sign_gets_a_park_and_a_bridge_sign_a_bridge
    person, seen = join

    place_sign(person, [30, 30], "PARK")
    paint(person, [[6, 5], [6, 6], [6, 7]], "water")
    place_sign(person, [5, 6], "BRIDGE")
    wait_until(timeout: 15) do
      tiles = read(person, "tiles")
      tiles["6,6"] == "bridge" &&
        tiles.any? { |k, tile| tile == "park" && City.distance(City.parse_key(k), [30, 30]) <= 2 }
    end

    assert_equal "a:planner", read(person, "authors")["6,6"]
    idle(seen)
  end

  # A stand-in mayor: reads every unknown sign as a park, names things in order.
  class StubMayor
    attr_reader :asked

    def initialize
      @asked = []
      @names = ["Elm Street", "Old Town"]
    end

    def read(text) = (@asked << text) && :park

    # The wishes given with the last name asked for are kept.
    attr_reader :wishes

    def name(_kind, wishes: [], **)
      @wishes = wishes
      @names.shift
    end
  end

  def park_near?(person, cell)
    read(person, "tiles").any? { |k, t| t == "park" && City.distance(City.parse_key(k), cell) <= City::SIGN_REACH }
  end

  def test_the_mayor_reads_a_sign_it_does_not_know_and_names_a_neighbourhood
    mayor = StubMayor.new
    person, seen = join(mayor: mayor)

    place_sign(person, [30, 30], "trees please")
    wait_until(timeout: 15) { read(person, "readings")["30,30"] == "PARK" && park_near?(person, [30, 30]) }

    assert_equal ["trees please"], mayor.asked

    paint(person, (0..7).map { |x| [x, 10] }, "road")
    paint(person, [[1, 9], [3, 9], [5, 9], [7, 9]], "house_red")
    place_sign(person, [6, 11], "name it after Ada")
    wait_until(timeout: 15) { read(person, "signs").value?("Elm Street") }
    key = read(person, "signs").key("Elm Street")

    assert_equal %w[sign a:mayor], [read(person, "tiles")[key], read(person, "authors")[key]]
    assert_equal 11, City.parse_key(key)[1], "the sign stands on the free side of the road"
    assert_equal ["name it after Ada"], mayor.wishes, "the sign beside the street went to the mayor as a wish"
    assert_equal ["trees please", "name it after Ada"], mayor.asked
    idle(seen)
  end

  def test_the_planner_leaves_when_stopped_and_clears_its_presence
    _person, seen = join

    @planner.stop
    @thread.join(5)

    refute_predicate @thread, :alive?
    wait_until { planner_state(seen).nil? }
  end
end
