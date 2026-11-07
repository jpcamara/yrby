require "test_helper"

# Per-connection limits in one process: the subscribe rate, the one frame
# bucket a socket uses across all its subscriptions, how often its seats are
# refreshed, and freeing the slot of a connection that went silent.
class ConnectionGuardTest < ActiveSupport::TestCase
  CID = "conn-1".freeze

  test "the subscribe rate is limited per connection" do
    guard = ConnectionGuard.new

    # Spend the whole subscribe burst at one instant (t=0).
    Limits::SUBSCRIBE_BURST.times { assert guard.admit_subscription(CID, 0) }

    assert_not guard.admit_subscription(CID, 0), "the next subscribe at the same instant is over the bucket"
    assert guard.admit_subscription("conn-2", 0), "another connection has its own bucket"
    assert guard.admit_subscription(CID, 1), "the bucket refills"
  end

  test "the connection shares one frame bucket that does not reset on subscribe" do
    guard = ConnectionGuard.new

    # Spend the frame burst at t=0.
    Limits::FRAME_BURST.times { assert guard.take_frame(CID, 0) }

    assert_not guard.take_frame(CID, 0), "over the burst, at the same instant"

    guard.admit_subscription(CID, 0)

    assert_not guard.take_frame(CID, 0), "a new subscription does not give the socket a new burst"
  end

  test "frame drops are counted per connection" do
    guard = ConnectionGuard.new
    Limits::FRAME_BURST.times { guard.take_frame(CID, 0) }
    5.times { guard.take_frame(CID, 0) }

    assert_equal 5, guard.frame_drops(CID)
  end

  test "a seat refresh is due at most once per interval" do
    guard = ConnectionGuard.new

    assert guard.seat_touch_due?(CID, 0)
    assert_not guard.seat_touch_due?(CID, Limits::SEAT_TOUCH_INTERVAL - 1)
    assert guard.seat_touch_due?(CID, Limits::SEAT_TOUCH_INTERVAL)
    assert guard.seat_touch_due?("conn-2", 1), "each connection has its own clock"
  end

  test "forget removes a connection's guard" do
    guard = ConnectionGuard.new
    guard.take_frame(CID, 0)
    guard.forget(CID)

    assert_equal 0, guard.count
  end

  test "sweep removes a guard this process stopped hearing from" do
    guard = ConnectionGuard.new(max_age: 60)
    guard.take_frame(CID, 0)

    assert_equal 0, guard.sweep(30, limiter: ConnectionLimiter.new), "still fresh before the TTL"
    assert_equal 1, guard.sweep(61, limiter: ConnectionLimiter.new), "removed past the TTL"
    assert_equal 0, guard.count
  end

  test "sweeping a leaked connection frees its connection slot" do
    limiter = ConnectionLimiter.new
    _status, token = limiter.acquire("1.2.3.4")
    guard = ConnectionGuard.new(max_age: 60)
    guard.register(CID, "1.2.3.4", token, 0)

    assert_equal 1, guard.sweep(61, limiter: limiter)
    assert_equal 0, limiter.count("1.2.3.4"), "the slot for its token is freed"
  end

  test "a connection that keeps sending awareness is kept by sweep" do
    limiter = ConnectionLimiter.new
    _status, token = limiter.acquire("1.2.3.4")
    guard = ConnectionGuard.new(max_age: 60)
    guard.register(CID, "1.2.3.4", token, 0)
    guard.take_frame(CID, 55) # any frame at t=55, awareness or document, updates seen_at

    assert_equal 0, guard.sweep(100, limiter: limiter), "last seen at 55, so 100 is within the TTL"
    assert_equal 1, limiter.count("1.2.3.4"), "the live connection keeps its slot"
  end
end
