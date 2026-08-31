require "test_helper"

class TokenBucketTest < ActiveSupport::TestCase
  test "the burst is spent, then frames are dropped" do
    bucket = TokenBucket.new(capacity: 3, refill_per_second: 1, now: 0)

    assert bucket.take(0)
    assert bucket.take(0)
    assert bucket.take(0)
    assert_not bucket.take(0)
    assert_equal 1, bucket.drops
  end

  test "tokens refill over time" do
    bucket = TokenBucket.new(capacity: 2, refill_per_second: 10, now: 0)
    2.times { bucket.take(0) }

    assert_not bucket.take(0)
    assert bucket.take(0.2), "0.2s at 10/s is two tokens back"
  end

  test "refill stops at capacity" do
    bucket = TokenBucket.new(capacity: 2, refill_per_second: 10, now: 0)
    bucket.take(0)

    # A minute of idling should not bank sixty seconds of tokens.
    assert bucket.take(60)
    assert bucket.take(60)
    assert_not bucket.take(60)
  end

  test "drops accumulate across the bucket's life" do
    bucket = TokenBucket.new(capacity: 1, refill_per_second: 0, now: 0)
    bucket.take(0)
    5.times { bucket.take(0) }

    assert_equal 5, bucket.drops
  end

  test "the site's configured rate lets a fast typist through" do
    bucket = TokenBucket.new(capacity: Limits::FRAME_BURST, refill_per_second: Limits::FRAMES_PER_SECOND, now: 0)
    # Ten frames a second for a minute: well inside a human editing session.
    allowed = (0...600).count { |i| bucket.take(i / 10.0) }

    assert_equal 600, allowed
  end
end
