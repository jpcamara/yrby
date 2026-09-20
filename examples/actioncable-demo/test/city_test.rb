# frozen_string_literal: true

require "city_helper"

class CityTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- one test per rule
  include CityFixture

  def road_plans(map) = City.plans(map).select { |plan| ["laying road", "building bridge"].include?(plan.goal) }
  def tiles_of(plan) = plan.cells.map(&:last).uniq

  def test_a_map_parses_and_drops_what_the_page_could_not_have_written
    assert_equal "road", TOWN[0, 3]
    assert_equal "house_red", TOWN[2, 2]
    assert_nil TOWN[0, 0]
    assert_equal [[2, 2], [6, 2], [7, 5]], TOWN.houses

    map = City::Map.from({ "1,1" => "road", "99,1" => "road", "2,2" => "castle", "x" => "road" },
                         { "1,1" => "PARK", "9,9" => 3 })

    assert_equal({ "1,1" => "road" }, map.tiles)
    assert_equal({ "1,1" => "PARK" }, map.signs)
  end

  def test_two_houses_with_no_road_get_a_road_between_them
    map = City::Map.parse("H.....H\n")

    plan = City.next_plan(map)

    assert_equal "laying road", plan.goal
    assert_equal [[1, 0, "road"], [2, 0, "road"], [3, 0, "road"], [4, 0, "road"], [5, 0, "road"]], plan.cells
    assert_nil City.next_plan(map.with(plan.cells)), "once built, both houses touch the road"
  end

  def test_a_house_off_the_road_gets_the_shortest_road_to_it_and_houses_on_it_get_nothing
    plans = road_plans(TOWN)

    assert_equal 1, plans.size, "only the house at 7,5 is off the road"
    assert_equal [[7, 4, "road"]], plans.first.cells
  end

  def test_a_lone_house_asks_for_nothing
    assert_nil City.next_plan(City::Map.parse("....\n.H..\n"))
  end

  def test_a_house_on_an_island_gets_a_bridge
    plan = City.next_plan(ISLAND)

    assert_equal "building bridge", plan.goal
    assert_equal [[2, 3, "bridge"], [2, 4, "road"]], plan.cells
    assert_nil City.next_plan(ISLAND.with(plan.cells))
  end

  def test_a_road_goes_around_water_when_that_is_cheaper
    map = City::Map.parse(<<~MAP)
      H..~..#
      ......#
    MAP

    plan = City.next_plan(map)

    assert_equal ["road"], tiles_of(plan), "through the gap, not over the water"
    assert_equal [[1, 0], [2, 0], [2, 1], [3, 1], [4, 1], [5, 1]], plan.positions
  end

  def test_a_no_build_sign_keeps_the_road_away
    map = City::Map.parse(<<~MAP, signs: { "5,4" => "no build here" })
      .....H....
      ..........
      ..........
      ..........
      .....!....
      ..........
      ..........
      ..........
      ##########
    MAP

    plan = City.next_plan(map)

    assert_equal "laying road", plan.goal
    assert(plan.positions.none? { |cell| City.distance(cell, [5, 4]) <= City::NO_BUILD_REACH })
    assert_equal 7, plan.positions.last[1], "it still reaches the road"
  end

  def test_a_district_of_ten_houses_gets_a_shop_by_its_road
    map = City::Map.parse(<<~MAP)
      HHHHHHHHH.....
      ##############
      ..............
    MAP

    assert_empty City.plans(map), "nine houses are not a district"

    ten = map.with([[9, 0, "house_blue"]])
    plan = City.next_plan(ten)

    assert_equal "opening a shop", plan.goal
    assert_equal 1, plan.cells.size
    x, y, tile = plan.cells.first

    assert_equal "shop@2x2", tile, "a shop is two cells by two, one key at its corner"
    assert_equal 2, y, "the free side of the road"
    assert_includes 4..5, x, "near the middle of the district"
    built = ten.with(plan.cells)

    assert_nil City.next_plan(built)
    assert_equal [[x, y], [x + 1, y], [x, y + 1], [x + 1, y + 1]], built.footprint(x + 1, y + 1)
    assert built.shop?(x + 1, y + 1)
  end

  def test_a_dense_block_gets_a_park
    map = City::Map.parse(<<~MAP)
      H#H#H#.
      #######
      H#H#H#.
      #######
      H#H#...
      .......
    MAP

    plan = City.next_plan(map)

    assert_equal "planting a park", plan.goal
    x, y, tile = plan.cells.first

    assert_equal "park", tile
    assert map.free?(x, y)
    assert_operator x, :<, 6
    assert_operator y, :<, 6
    assert_nil City.next_plan(map.with(plan.cells))
  end

  def test_a_park_sign_plants_a_park_beside_it_once
    map = City::Map.parse("....!....\n", signs: { "4,0" => "a park please" })

    plan = City.next_plan(map)

    assert_equal "planting a park", plan.goal
    assert_equal [[3, 0, "park"]], plan.cells
    assert_nil City.next_plan(map.with(plan.cells))
  end

  def test_a_shop_sign_prefers_a_site_by_a_road_where_its_four_cells_fit
    map = City::Map.parse(<<~MAP, signs: { "1,0" => "SHOP" })
      .!...
      .....
      #####
    MAP

    plan = City.next_plan(map)

    assert_equal "opening a shop", plan.goal
    assert_equal [[2, 0, "shop@2x2"]], plan.cells, "not over the sign, and down against the road"
    assert_nil City.next_plan(map.with(plan.cells))
  end

  def test_a_road_sign_gets_a_road_to_the_nearest_road
    map = City::Map.parse(<<~MAP, signs: { "0,0" => "ROAD" })
      !....
      .....
      .....
      #####
    MAP

    assert_equal [[0, 1, "road"], [0, 2, "road"]], City.next_plan(map).cells
  end

  def test_a_bridge_sign_by_water_gets_a_bridge_straight_across
    map = City::Map.parse(<<~MAP, signs: { "0,1" => "BRIDGE" })
      .~~~..
      !~~~..
      .~~~..
    MAP

    plan = City.next_plan(map)

    assert_equal "building bridge", plan.goal
    assert_equal [[1, 1, "bridge"], [2, 1, "bridge"], [3, 1, "bridge"]], plan.cells
    assert_nil City.next_plan(map.with(plan.cells))
  end

  def test_a_clear_sign_takes_out_roads_and_parks_but_not_houses
    map = City::Map.parse(<<~MAP, signs: { "2,1" => "CLEAR" })
      ##P##
      H.!.H
      ~~~~~
    MAP

    plan = City.next_plan(map)

    assert_equal "clearing", plan.goal
    assert_equal [[0, 0, nil], [1, 0, nil], [2, 0, nil], [3, 0, nil], [4, 0, nil]], plan.cells
    cleared = map.with(plan.cells)

    assert_equal [[0, 1], [4, 1]], cleared.houses
    assert cleared.water?(0, 2)
    assert_empty(City.plans(cleared).select { |p| p.goal == "clearing" })
  end

  def test_a_sign_that_says_something_else_is_only_a_sign
    map = City::Map.parse("!...\n", signs: { "0,0" => "Main Street" })

    assert_empty City.plans(map)
    assert_nil City.instruction("Main Street")
    assert_equal :no_build, City.instruction("NO BUILD zone")
    assert_equal :park, City.instruction("park here")
  end

  def test_signs_come_before_roads_and_avoided_cells_are_left_alone
    map = City::Map.parse(<<~MAP, signs: { "9,0" => "PARK" })
      H.....H..!
    MAP

    plans = City.plans(map)

    assert_equal ["planting a park", "laying road"], plans.map(&:goal)

    detour = City.next_plan(City::Map.parse("H.....H\n"), [[3, 0]])

    assert_equal 7, detour.cells.size, "around the cell someone just wrote to"
    assert(detour.positions.none? { |cell| cell == [3, 0] })
  end

  def test_a_reading_makes_a_sign_an_instruction_and_a_plain_sign_is_a_name
    map = City::Map.parse("!...!\n", signs: { "0,0" => "trees please", "4,0" => "Elm Street" },
                                     readings: { "0,0" => "PARK", "4,0" => "none" })

    assert_equal :park, map.instruction_at(0, 0)
    assert_nil map.instruction_at(4, 0)
    assert_equal [[4, 0, "Elm Street"]], map.name_signs
    assert_equal "planting a park", City.next_plan(map).goal
  end

  def test_a_neighbourhood_or_a_long_street_without_a_name_sign_gets_a_site_for_one
    town = City::Map.parse(<<~MAP)
      .H.H.H.H..
      ##########
      ..........
    MAP

    kind, (x, y) = City.naming_sites(town).first

    assert_equal "district", kind
    assert_equal 2, y, "on the free side of the road"
    assert_includes 3..4, x, "near the middle of the houses"

    named = City::Map.parse(<<~MAP, signs: { "4,2" => "Elm Street" })
      .H.H.H.H..
      ##########
      ....!.....
    MAP

    assert_empty City.naming_sites(named)
    assert_empty City.naming_sites(City::Map.parse("#####\n")), "a short road is not a street"
    assert_equal [["street", [4, 1]]], City.naming_sites(City::Map.parse("##########\n..........\n"))
  end

  def test_near_is_within_the_yield_reach
    assert City.near?([[10, 10]], [[13, 13]], 3)
    refute City.near?([[10, 10]], [[14, 10]], 3)
    refute City.near?([], [[10, 10]], 3)
  end
  # --- footprints, the land, and cable car track -----------------------------

  def test_a_tile_value_carries_its_footprint
    assert_equal ["shop", 2, 2], City.parse_tile("shop@2x2")
    assert_equal ["road", 1, 1], City.parse_tile("road")
    assert_nil City.parse_tile("castle")
    assert_nil City.parse_tile("shop@9x9")
    assert_nil City.parse_tile("shop@2x2x2")
    assert_equal "shop@2x2", City.sized("shop")
    assert_equal "grand@2x3", City.sized("grand")
    assert_equal "park", City.sized("park")
  end

  def test_a_wide_building_covers_its_cells_from_one_key
    map = City::Map.from({ "2,0" => "victorian_teal@2x2", "0,0" => "house_red" }, {})

    assert_equal "victorian_teal", map[3, 1]
    assert_equal({ "3,0" => "2,0", "2,1" => "2,0", "3,1" => "2,0" }, map.cover)
    assert_equal [[0, 0], [2, 0]], map.houses, "anchors only"
    refute map.free?(3, 1)
    assert map.free?(4, 1)
    assert_equal [[2, 0], [3, 0], [2, 1], [3, 1]], map.footprint(3, 1)
    assert_equal [[2, 0]], map.footprint(2, 0).first(1)
    beside = map.beside(3, 1)

    assert_includes beside, [4, 0]
    assert_includes beside, [2, 2]
    refute_includes beside, [2, 1]
    refute map.touches_road?(2, 0)
    assert map.with([[4, 1, "road"]]).touches_road?(2, 0), "a road by any of its cells"
    assert map.fits?(5, 5, "shop")
    refute map.fits?(1, 0, "shop"), "over the house at 2,0"
    refute map.fits?(95, 95, "shop"), "off the map"
  end

  def test_a_road_goes_around_a_wide_building
    map = City::Map.from({ "0,0" => "house_red", "2,0" => "shop@2x2", "6,0" => "house_blue" }, {})

    plan = City.next_plan(map)

    assert_equal "laying road", plan.goal
    assert(plan.positions.none? { |c| map.footprint(2, 0).include?(c) }, "not through the shop")
    assert_operator plan.cells.size, :>=, 7
    assert_nil City.next_plan(map.with(plan.cells))
    wide = City::Map.from({ "0,0" => "victorian_teal@2x2", "6,0" => "house_blue" }, {})

    assert_equal "laying road", City.next_plan(wide).goal
    assert_equal [[2, 0, "road"]], City.next_plan(wide).cells.first(1), "from the Victorian's east side"
  end

  def test_the_terrain_is_the_page_s_arithmetic_exactly
    # The same calls in frontend/src/city.js give these doubles, and a
    # delta of zero asks for the same doubles, not nearly the same.
    assert_in_delta(0.9740993683226407, City::Terrain.hash32(3, 5, 42), 0.0)
    assert_in_delta(0.573110266122967, City::Terrain.hash32(0, 0, 1_622_029_271), 0.0)
    assert_in_delta(0.18040842586842132, City::Terrain.noise(42, 10, 20, 16), 0.0)
    assert_in_delta(0.8333554713865986, City::Terrain.noise(1_622_029_272, 77, 13, 7), 0.0)
    assert_in_delta(0.42613613145402823, City::Terrain.elevation(1_622_029_271, 10, 20), 0.0)
    terrain = City::Terrain.for(1_622_029_271)
    shore = (0...City::HEIGHT).map { |y| (0...City::WIDTH).find { |x| terrain.water?(x, y) } }

    assert_equal [87, 87, 86, 85, 84, 83, 82, 81, 81, 81], shore.first(10)
    assert_equal [86, 87, 87, 87, 87, 87, 86, 86, 85, 85, 84], shore.last(11)
  end

  def test_the_land_has_a_bay_along_the_east_edge_and_hills_in_bands
    terrain = City::Terrain.for(42)

    assert terrain.water?(95, 10)
    refute terrain.water?(0, 10)
    assert_same terrain, City::Terrain.for(42)
    bands = (0...City::HEIGHT).flat_map { |y| (0...City::WIDTH).map { |x| terrain.band(x, y) } }.uniq.sort

    assert_operator bands.size, :>=, 3, "hills in more than one band"
    assert_equal 0, terrain.band(94, 10), "flat by the bay"
    assert_equal 0, City::Terrain::FLAT.band(3, 3)
    refute City::Terrain::FLAT.water?(95, 95)
    assert_nil City::Map.parse("H..\n").seed
  end

  def test_the_bay_is_water_unless_someone_filled_it_in
    map = City::Map.parse("H....\n", seed: 42)

    assert map.water?(94, 40)
    refute map.free?(94, 40)
    assert_nil map[94, 40], "the bay is land, not a tile"
    filled = map.with([[94, 40, "grass"]])

    refute filled.water?(94, 40)
    assert filled.free?(94, 40)
    assert filled.free?(1, 0), "an explicit grass tile is as free as none"
    assert_equal 7,
                 City.plans(City::Map.from({ "20,40" => "house_red", "28,40" => "house_blue" }, {},
                                           seed: 42)).first.cells.size
  end

  def test_a_road_climbs_a_steep_step_on_cable_car_track # rubocop:disable Metrics/AbcSize -- the step, the surfaces, and the plan
    map = City::Map.parse("", seed: 42)
    steep = (0...(City::HEIGHT - 1)).flat_map { |y| (0...(City::WIDTH - 20)).map { |x| [[x, y], [x + 1, y]] } }
                                    .find { |a, b| map.steep?(a, b) && map.free?(*a) && map.free?(*b) }
    (a, b) = steep

    assert_equal %w[road cable cable road], City.surfaces(map, [[a[0] - 1, a[1]], a, b, [b[0] + 1, b[1]]])
    assert_equal %w[road road], City.surfaces(City::Map.parse(""), [[1, 1], [2, 1]]), "flat land, plain road"
    assert_equal %w[bridge road], City.surfaces(City::Map.parse("~.\n"), [[0, 0], [1, 0]])
    houses = City::Map.from({ City.key(a[0] - 2, a[1]) => "house_red", City.key(b[0] + 2, b[1]) => "house_blue" }, {},
                            seed: 42)
    plan = City.next_plan(houses)

    assert_equal "laying cable car track", plan.goal
    assert_includes plan.cells.map(&:last), "cable"
    assert houses.with(plan.cells).road?(*a), "track counts as road"
    assert_nil City.next_plan(houses.with(plan.cells))
  end

  def test_a_clear_sign_leaves_props_alone_and_takes_cable_track
    map = City::Map.parse(<<~MAP, signs: { "2,1" => "CLEAR" })
      %%S..
      ..!..
    MAP
    map = map.with([[4, 1, "lamp"]])

    plan = City.next_plan(map)

    assert_equal [[0, 0, nil], [1, 0, nil], [2, 0, nil]], plan.cells, "the track and the shop, by its anchor"
    assert_equal "lamp", map.with(plan.cells)[4, 1]
  end
end
