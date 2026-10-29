require "test_helper"

class AgentSeatsTest < ActiveSupport::TestCase
  test "one agent per person in a room, a limit per room, and a limit across rooms" do
    seats = AgentSeats.new(max: 3, per_room: 2)

    assert_equal :ok, seats.take("a", "ada")
    assert_equal :here, seats.take("a", "ada")
    assert_equal :ok, seats.take("a", "linus")
    assert_equal :full, seats.take("a", "grace")
    assert_equal :ok, seats.take("b", "ada")
    assert_equal :full, seats.take("c", "ada")
    seats.release("a", "ada")

    assert_equal :ok, seats.take("c", "ada")
  end

  test "model calls stop at the daily budget and start again the next day" do
    day = Date.new(2026, 11, 10)
    seats = AgentSeats.new(calls_per_day: 2, clock: -> { day })

    assert seats.spend_call
    assert seats.spend_call
    refute seats.spend_call

    day += 1

    assert seats.spend_call
  end
end
