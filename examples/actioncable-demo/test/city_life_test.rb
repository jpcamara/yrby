# frozen_string_literal: true

require "city_helper"
require "city_cable"

# The town's life: the rules in CityLife::Town, stepped by hand, and the
# peer against a real cable, joined over one socket with a person on
# another, its whole life in its presence and nothing in the document.
class CityLifeTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- the rules, then the peer
  # rubocop:disable Metrics/AbcSize -- assertion-dense, as the gem's own tests are allowed to be
  include CityCable

  TICK = CityLife::TICK

  def setup
    @key = "life-#{rand(1 << 32)}"
  end

  def teardown
    @life&.stop
    @thread&.join(5)
    close_clients
  end

  def town(map, seed: 1) = CityLife::Town.new(map, rng: Random.new(seed), now: 0.0)
  def steps(town, count, from: 0) = count.times { |i| town.step((from + i) * TICK) }
  def positions(town) = town.walkers.map { |w| [w.x, w.y] }

  STREET = City::Map.parse(<<~MAP)
    H.....H.....H
    #############
    ....S........
  MAP

  def test_the_townsfolk_take_to_the_roads_and_keep_to_them
    t = town(STREET)
    steps(t, 30)

    assert_equal 13, t.walkers.size, "twelve, and one more for every two houses"
    assert_equal 13, t.walkers.map(&:name).uniq.size
    roads = Set.new(STREET.roads)

    assert(positions(t).all? { |cell| roads.include?(cell) }, "everyone stays on the road")
    assert_operator positions(t).uniq.size, :>, 3, "they spread out along it"
  end

  def test_someone_stops_at_the_shop
    t = town(STREET)
    stops = Set.new(STREET.beside(4, 2).select { |c| STREET.road?(*c) })
    paused = false
    60.times do |i|
      t.step(i * TICK)
      paused ||= t.walkers.any? { |w| w.wait.positive? && stops.include?([w.x, w.y]) }
    end

    assert paused, "a walker paused on the road outside the shop"
  end

  def test_without_roads_they_stroll_over_the_grass
    t = town(City::Map.parse("H...\n"))
    steps(t, 12)

    assert_equal 12, t.walkers.size
    assert_operator positions(t).uniq.size, :>, 4
    assert(positions(t).all? { |x, y| x.between?(0, City::WIDTH - 1) && y.between?(0, City::HEIGHT - 1) })
  end

  def test_one_bubble_at_a_time_and_it_goes_away
    t = town(STREET)
    spoken = []
    40.times do |i|
      t.step(i * TICK)
      talking = t.walkers.select(&:say)
      spoken.concat(talking.map { |w| [w.name, w.say] })

      assert_operator talking.size, :<=, 2, "at most the last two lines are up"
    end

    assert_operator spoken.map(&:first).uniq.size, :>=, 3, "different people spoke"
    assert(spoken.map(&:last).all? { |line| line.is_a?(String) && !line.empty? })
    t.walkers.each do |w|
      w.say = "hi"
      w.say_until = 1.0
    end
    t.step(100.0)

    assert(t.walkers.none? { |w| w.say == "hi" }, "a bubble comes down after its time")
    assert_operator t.walkers.count(&:say), :<=, 1, "and at most one new one went up"
  end

  def test_what_they_say_is_about_what_is_around_them
    lines = 30.times.map { |i| town(City::Map.parse("H...\n"), seed: i).send(:line_for, CityLife::Town::Walker.new(x: 1, y: 0, said_at: 0)) }

    assert(lines.all? { |l| ["where's the bakery?", "no shops yet?", "I could use a coffee"].include?(l) })
    by_bridge = City::Map.parse("H=~\n")

    assert_includes ["nice bridge", "what a view!", "is it foggy out there?"],
                    town(by_bridge).send(:line_for, CityLife::Town::Walker.new(x: 0, y: 0, said_at: 0))
    signed = City::Map.parse("!..\n", signs: { "0,0" => "Elm Street" })

    assert_equal "it says: Elm Street",
                 town(signed, seed: 3).send(:line_for, CityLife::Town::Walker.new(x: 1, y: 0, said_at: 0))
  end

  def test_cars_drive_the_roads_and_the_cable_car_keeps_to_the_track
    map = City::Map.parse(<<~MAP)
      ##############################
      #............................#
      ##############################
      ..............................
      %%%%%%%%%%%%%%
    MAP
    t = town(map)
    roads = Set.new(map.roads)
    track = Set.new(map.cells_with([City::CABLE]))
    40.times do |i|
      t.step(i * TICK)
      trams, cars = t.cars.partition { |c| c.kind == "tram" }

      assert_equal 4, cars.size, "one car per fifteen cells of road, up to four"
      assert_equal 1, trams.size, "one cable car for the track"
      assert(cars.all? { |c| roads.include?([c.x, c.y]) })
      assert(trams.all? { |c| track.include?([c.x, c.y]) })
    end

    assert_operator t.state[:cars].map { |c| c.first(2) }.uniq.size, :>, 1
  end

  def test_gulls_and_boats_keep_to_the_bay_and_chimneys_smoke
    map = City::Map.parse("H.H.H.H\n", seed: 7)
    t = town(map)
    30.times do |i|
      t.step(i * TICK)

      assert_equal 3, t.gulls.size
      assert_equal 2, t.boats.size
      assert(t.boats.all? { |b| map.water?(b.x, b.y) }, "boats stay on the water")
    end

    assert(t.gulls.all? { |g| g.x >= City::WIDTH - 30 }, "gulls keep to the bay side")
    houses = map.houses.map { |x, y| City.key(x, y) }

    assert(t.smoke.all? { |k| houses.include?(k) })
    assert_empty town(City::Map.parse("H.H\n")).tap { |flat| steps(flat, 3) }.gulls, "no water, no gulls"
  end

  def test_the_clock_turns_through_the_day
    t = town(STREET)
    t.step(0.0)

    assert_in_delta 0.3, t.clock, 0.001
    t.step(CityLife::Town::DAY / 2)

    assert_in_delta 0.8, t.clock, 0.001
    t.step(CityLife::Town::DAY)

    assert_in_delta 0.3, t.clock, 0.001
  end

  def test_the_state_is_small_arrays_the_page_can_ease_between
    t = town(STREET)
    steps(t, 4)
    state = t.state

    assert_equal %i[clock peds cars gulls boats smoke], state.keys
    name, sprite, x, y, face, say = state[:peds].first

    assert_kind_of String, name
    assert_includes 0..7, sprite
    assert(STREET.road?(x, y))
    assert_includes [-1, 1], face
    assert(say.nil? || say.is_a?(String))
    assert_operator JSON.generate(state).bytesize, :<, 2000, "a frame twice a second stays small"
  end

  def test_the_map_can_change_under_their_feet
    t = town(STREET)
    steps(t, 10)
    t.map = City::Map.parse("H.....H.....H\n")
    steps(t, 10, from: 10)

    assert_equal 13, t.walkers.size
    assert(positions(t).all? { |x, y| t.map.free?(x, y) }, "off the roads that are gone, onto the grass")
  end

  # --- the peer -------------------------------------------------------------

  def life_state(seen) = seen.states.values.find { |s| s.is_a?(Hash) && s["life"] }

  def test_the_townsfolk_join_as_a_peer_and_live_in_their_presence_only
    seen = Y::Awareness.new
    person = client.on_awareness { |frame| seen.apply_update(frame) }.subscribe
    person.send_update(person.doc.diff do |d|
      (10..20).each { |x| d.get_map("tiles")[City.key(x, 10)] = "road" }
      d.get_map("tiles")["10,9"] = "house_red"
      d.get_map("meta")["seed"] = 99
    end)
    @life = CityLife.new(@key, peer: client, logger: Logger.new(File::NULL))
    @thread = Thread.new { @life.run }
    wait_until { life_state(seen) }
    present(person)
    wait_until(timeout: 15) { life_state(seen)["peds"].to_a.size >= 12 }
    state = life_state(seen)

    assert_equal({ "name" => "Townsfolk", "color" => "#7c9c4a" }, state["user"])
    assert_match(/\A\d+ out and about\z/, state["status"])
    assert(state["peds"].all? { |ped| ped[3] == 10 && ped[2].between?(10, 20) }, "on the road")
    assert_operator state["gulls"].size, :>, 0, "the seed gives the town a bay"
    before = recorded(@key)
    sleep 1.5

    assert_equal before, recorded(@key), "the server recorded nothing from the townsfolk"
    assert_equal(%w[meta tiles], %w[meta tiles].select { |name| read(person, name).any? })

    @life.stop
    @thread.join(5)

    refute_predicate @thread, :alive?
    wait_until { life_state(seen).nil? }
  end
  # rubocop:enable Metrics/AbcSize
end
