# frozen_string_literal: true

# The city tests load the rules and the planner without booting Rails: they
# need yrby and the cable client, nothing of the app's.
#
#   bundle exec ruby -Itest test/city_test.rb
#   bundle exec ruby -Itest test/city_planner_test.rb
require "minitest/autorun"
require "y"
require_relative "../app/lib/city"
require_relative "../app/lib/city_planner"

module CityFixture
  # A road across the middle, two houses on it, one off it.
  TOWN = City::Map.parse(<<~MAP)
    ..........
    ..........
    ..H...H...
    ##########
    ..........
    .......H..
  MAP

  # A house on an island, a road on the mainland.
  ISLAND = City::Map.parse(<<~MAP)
    ..........
    .~~~~.....
    .~H~~.....
    .~~~~.....
    ..........
    ##########
  MAP
end
