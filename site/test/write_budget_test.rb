require "test_helper"

# The process-wide document-write shelf in front of SQLite.
class WriteBudgetTest < ActiveSupport::TestCase
  test "writes within the burst are admitted" do
    budget = WriteBudget.new(capacity: 3, refill_per_second: 1, now: 0)

    assert budget.admit(0)
    assert budget.admit(0)
    assert budget.admit(0)
  end

  test "writes past the burst are shed at one instant" do
    budget = WriteBudget.new(capacity: 3, refill_per_second: 1, now: 0)
    3.times { budget.admit(0) }

    assert_not budget.admit(0), "over the burst"
    assert_equal 1, budget.shed
  end

  test "the bucket refills over time" do
    budget = WriteBudget.new(capacity: 2, refill_per_second: 1, now: 0)
    2.times { budget.admit(0) }

    assert_not budget.admit(0)
    assert budget.admit(1), "a second later, one token is back"
  end
end
