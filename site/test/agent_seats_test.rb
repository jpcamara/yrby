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

  # The web server takes a seat and a job process gives it back, so the
  # seats and the budget are rows, the same from every process.
  test "seats and the budget are shared by every process" do
    web = AgentSeats.new(max: 1, calls_per_day: 1)
    jobs = AgentSeats.new(max: 1, calls_per_day: 1)

    assert_equal :ok, web.take("a", "ada")
    assert_equal :full, jobs.take("b", "linus")
    jobs.release("a", "ada")

    assert_equal :ok, web.take("b", "linus")
    assert jobs.spend_call
    refute web.spend_call
  end

  test "a seat outlasting any agent's stay belongs to a dead process and is taken back" do
    seats = AgentSeats.new(max: 1)
    seats.take("a", "ada")
    AgentSeats::Seat.update_all(created_at: (AgentSeats::STALE + 1).seconds.ago)

    assert_equal :ok, seats.take("b", "linus")
  end
end
