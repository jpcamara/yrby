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

    assert_equal "shop", tile
    assert_equal 2, y, "the free side of the road"
    assert_includes 4..5, x, "near the middle of the district"
    assert_nil City.next_plan(ten.with(plan.cells))
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

  def test_a_shop_sign_prefers_a_cell_by_a_road
    map = City::Map.parse(<<~MAP, signs: { "1,0" => "SHOP" })
      .!...
      .....
      #####
    MAP

    plan = City.next_plan(map)

    assert_equal "opening a shop", plan.goal
    assert_equal [[1, 1, "shop"]], plan.cells
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

  def test_near_is_within_the_yield_reach
    assert City.near?([[10, 10]], [[13, 13]], 3)
    refute City.near?([[10, 10]], [[14, 10]], 3)
    refute City.near?([], [[10, 10]], 3)
  end
end
