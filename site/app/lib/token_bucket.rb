# A token bucket, one per subscription, in front of the channel's receive path.
#
# yrby validates every frame before anything touches it, so a malformed or
# oversized frame is already dropped. This is about volume: a well-formed client
# sending ten thousand valid updates a second is still a denial of service, and
# validity says nothing about rate.
#
# `capacity` tokens accumulate at `refill_per_second`, one token per frame. A
# client under the rate never notices. A client over it has frames dropped,
# which for a document update means the client keeps it queued and retries —
# the same shape as any other dropped frame in the protocol.
class TokenBucket
  attr_reader :drops

  def initialize(capacity:, refill_per_second:, now: monotonic)
    @capacity = capacity.to_f
    @refill = refill_per_second.to_f
    @tokens = @capacity
    @updated_at = now
    @drops = 0
  end

  # True when the frame is allowed. False when the bucket is empty, and the
  # caller should drop the frame.
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

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
