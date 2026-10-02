require "test_helper"

# Per-connection limits: subscription count, subscribe rate, and the single
# frame bucket a socket carries across all its subscriptions.
class ConnectionGuardTest < ActiveSupport::TestCase
  CID = "conn-1".freeze

  test "a connection may hold up to the subscription cap, then no more" do
    guard = ConnectionGuard.new(max_subscriptions: 2)

    assert_equal :ok, guard.admit_subscription(CID, "tiptap/a", 0)
    assert_equal :ok, guard.admit_subscription(CID, "tiptap/b", 0)
    assert_equal :too_many, guard.admit_subscription(CID, "tiptap/c", 0)
    assert_equal 2, guard.subscriptions(CID)
  end

  test "a connection cannot take two seats in the same room" do
    guard = ConnectionGuard.new(max_subscriptions: 10)

    assert_equal :ok, guard.admit_subscription(CID, "tiptap/a", 0)
    assert_equal :duplicate, guard.admit_subscription(CID, "tiptap/a", 0)
    assert_equal 1, guard.subscriptions(CID)
  end

  test "releasing a subscription frees a slot" do
    guard = ConnectionGuard.new(max_subscriptions: 1)
    guard.admit_subscription(CID, "tiptap/a", 0)

    assert_equal :too_many, guard.admit_subscription(CID, "tiptap/b", 0)

    guard.release_subscription(CID, "tiptap/a", 0)

    assert_equal :ok, guard.admit_subscription(CID, "tiptap/b", 0)
  end

  test "the subscribe rate is bounded and does not refill on unsubscribe" do
    guard = ConnectionGuard.new(max_subscriptions: 10_000)

    # Spend the whole subscribe burst at one instant (t=0).
    Limits::SUBSCRIBE_BURST.times { |i| assert_equal :ok, guard.admit_subscription(CID, "tiptap/#{i}", 0) }

    # The next subscribe at the same instant is over the bucket.
    assert_equal :rate_limited, guard.admit_subscription(CID, "tiptap/over", 0)

    # Unsubscribing and trying again does NOT hand out a fresh burst: the bucket
    # is the connection's, not the subscription's.
    guard.release_subscription(CID, "tiptap/0", 0)

    assert_equal :rate_limited, guard.admit_subscription(CID, "tiptap/again", 0)
  end

  test "one frame bucket serves the whole connection and does not reset on subscribe" do
    guard = ConnectionGuard.new(max_subscriptions: 10)
    guard.admit_subscription(CID, "tiptap/a", 0)

    # Spend the frame burst at t=0.
    Limits::FRAME_BURST.times { assert guard.take_frame(CID, 0) }

    assert_not guard.take_frame(CID, 0), "over the burst, at the same instant"

    # Re-subscribing must not refill the frame bucket: the reset/multiply hole.
    guard.release_subscription(CID, "tiptap/a", 0)
    guard.admit_subscription(CID, "tiptap/b", 0)

    assert_not guard.take_frame(CID, 0), "a new subscription does not hand the socket a fresh burst"
  end

  test "frame drops accumulate for the connection and drive the flood close" do
    guard = ConnectionGuard.new
    Limits::FRAME_BURST.times { guard.take_frame(CID, 0) }
    5.times { guard.take_frame(CID, 0) }

    assert_equal 5, guard.frame_drops(CID)
  end

  test "forget drops a connection's guard entirely" do
    guard = ConnectionGuard.new(max_subscriptions: 1)
    guard.admit_subscription(CID, "tiptap/a", 0)
    guard.forget(CID)

    assert_equal 0, guard.subscriptions(CID)
    assert_equal :ok, guard.admit_subscription(CID, "tiptap/b", 0), "a fresh guard after forget"
  end

  test "sweep reaps a guard whose disconnect never arrived" do
    guard = ConnectionGuard.new(max_age: 60)
    guard.admit_subscription(CID, "tiptap/a", 0) # last seen at t=0, never released

    assert_equal 0, guard.sweep(30, rooms: Rooms.new, limiter: ConnectionLimiter.new), "still fresh before the TTL"
    assert_equal 1, guard.sweep(61, rooms: Rooms.new, limiter: ConnectionLimiter.new), "reaped past the TTL"
    assert_equal 0, guard.count
  end

  test "reaping a leaked connection frees its room seat and its connection slot" do
    rooms = Rooms.new
    limiter = ConnectionLimiter.new
    _status, token = limiter.acquire("1.2.3.4")
    rooms.join("tiptap/a") # the seat the leaked connection holds

    guard = ConnectionGuard.new(max_age: 60)
    guard.register(CID, "1.2.3.4", token, 0)
    guard.admit_subscription(CID, "tiptap/a", 0)

    assert_equal 1, guard.sweep(61, rooms: rooms, limiter: limiter)
    assert_equal 0, rooms.peers("tiptap/a"), "the seat is freed, so the room is joinable and evictable"
    assert_empty rooms.occupied_keys
    assert_equal 0, limiter.count("1.2.3.4"), "the connection slot is freed by its exact token"
  end

  test "a connection still emitting awareness is never reaped" do
    rooms = Rooms.new
    limiter = ConnectionLimiter.new
    _status, token = limiter.acquire("1.2.3.4")
    rooms.join("tiptap/a")

    guard = ConnectionGuard.new(max_age: 60)
    guard.register(CID, "1.2.3.4", token, 0)
    guard.admit_subscription(CID, "tiptap/a", 0)
    guard.take_frame(CID, 55) # an awareness (or document) frame at t=55 refreshes liveness

    assert_equal 0, guard.sweep(100, rooms: rooms, limiter: limiter),
                 "seen at 55, so 100 is within the TTL of the last frame"
    assert_equal 1, rooms.peers("tiptap/a"), "the live connection keeps its seat"
    assert_equal 1, limiter.count("1.2.3.4"), "and its slot"
  end
end
