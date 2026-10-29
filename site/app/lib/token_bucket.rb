# A token bucket for rate limits. ConnectionGuard keeps two per connection (for
# frames and for subscribes), and WriteBudget keeps one for the whole process.
#
# yrby validates every frame first and drops malformed or oversized ones. This
# limits volume. A well-formed client sending ten thousand valid updates a
# second is still a denial of service.
#
# The bucket holds up to `capacity` tokens and refills at `refill_per_second`.
# Each frame takes one token. A client under the rate never notices. A client
# over it has frames dropped. For a document update, the client keeps the
# update queued and retries it, the same as for any other dropped frame.
#
# `dump` returns three numbers and `load` rebuilds a bucket from them, in case
# a bucket needs to be stored between RPC calls.
class TokenBucket
  attr_reader :drops

  def self.load(dumped, capacity:, refill_per_second:)
    bucket = new(capacity: capacity, refill_per_second: refill_per_second)
    dumped ? bucket.restore(dumped) : bucket
  end

  def initialize(capacity:, refill_per_second:, now: monotonic)
    @capacity = capacity.to_f
    @refill = refill_per_second.to_f
    @tokens = @capacity
    @updated_at = now
    @drops = 0
  end

  # Returns true when the frame is allowed, and false when the bucket is empty
  # and the caller should drop the frame.
  def take(now = monotonic)
    @tokens = [@capacity, @tokens + ((now - @updated_at) * @refill)].min
    @updated_at = now
    if @tokens < 1
      @drops += 1
      return false
    end

    @tokens -= 1
    true
  end

  def dump = [@tokens, @updated_at, @drops]

  def restore(dumped)
    tokens, updated_at, drops = dumped
    @tokens = tokens.to_f
    @updated_at = updated_at.to_f
    @drops = drops.to_i
    self
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
